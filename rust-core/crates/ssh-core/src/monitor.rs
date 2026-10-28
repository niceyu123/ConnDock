use crate::RemoteError;
use crate::remote::{RemoteContext, checked, on_runtime};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::{Mutex, watch};

// No host, path, interface, or command supplied by a caller is interpolated.
const COLLECT_COMMAND: &str = r#"LC_ALL=C; export LC_ALL
if [ "$(uname -s)" != Linux ]; then exit 72; fi
printf '__CONNDOCK_SYSTEM__\n'; uname -sr || exit 73
printf '__CONNDOCK_STAT__\n'; cat /proc/stat || exit 73
printf '__CONNDOCK_MEMORY__\n'; cat /proc/meminfo || exit 73
printf '__CONNDOCK_NETWORK__\n'; cat /proc/net/dev || exit 73
printf '__CONNDOCK_UPTIME__\n'; cat /proc/uptime || exit 73
printf '__CONNDOCK_DISK__\n'; df -Pk / || exit 73
printf '__CONNDOCK_END__\n'
"#;

#[derive(Clone, Debug, PartialEq)]
pub struct LinuxSample {
    pub system: String,
    pub uptime_seconds: f64,
    pub memory_total: u64,
    pub memory_available: u64,
    pub disk_total: u64,
    pub disk_used: u64,
    pub disk_available: u64,
    pub disk_percent: f64,
    pub cpu: [u64; 8],
    pub interfaces: BTreeMap<String, (u64, u64)>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LinuxMetrics {
    pub system: String,
    pub uptime_seconds: f64,
    pub cpu_percent: Option<f64>,
    pub memory_total: u64,
    pub memory_used: u64,
    pub disk_total: u64,
    pub disk_used: u64,
    pub disk_percent: f64,
    pub receive_bytes_per_second: Option<f64>,
    pub transmit_bytes_per_second: Option<f64>,
}

#[derive(Clone)]
pub struct LinuxMonitor {
    context: RemoteContext,
    cancelled: watch::Sender<bool>,
    previous: Arc<Mutex<Option<(Instant, LinuxSample)>>>,
}
impl crate::SshSession {
    pub fn linux_monitor(&self) -> Result<LinuxMonitor, RemoteError> {
        let (cancelled, _) = watch::channel(false);
        Ok(LinuxMonitor {
            context: self.remote_context()?,
            cancelled,
            previous: Arc::new(Mutex::new(None)),
        })
    }
}
impl LinuxMonitor {
    pub fn stop(&self) {
        self.cancelled.send_replace(true);
    }
    pub async fn sample(&self) -> Result<LinuxMetrics, RemoteError> {
        let monitor = self.clone();
        on_runtime(async move {
            checked(
                monitor.context.cancelled.clone(),
                monitor.cancelled.subscribe(),
                async {
                    let mut previous = monitor.previous.lock().await;
                    let mut lease = monitor.context.open_channel().await?;
                    let channel = lease.channel.as_mut().ok_or(RemoteError::ConnectionLost)?;
                    channel
                        .exec(true, COLLECT_COMMAND)
                        .await
                        .map_err(|_| RemoteError::ConnectionLost)?;
                    let mut output = Vec::new();
                    let mut exit_status = None;
                    let mut accepted = false;
                    loop {
                        match channel.wait().await {
                            Some(russh::ChannelMsg::Success) => accepted = true,
                            Some(russh::ChannelMsg::Failure) => {
                                return Err(RemoteError::Unsupported);
                            }
                            Some(russh::ChannelMsg::Data { data }) => {
                                if output.len() + data.len() > 256 * 1024 {
                                    return Err(RemoteError::OutputLimit);
                                }
                                output.extend_from_slice(&data);
                            }
                            Some(russh::ChannelMsg::ExitStatus {
                                exit_status: status,
                            }) => exit_status = Some(status),
                            Some(russh::ChannelMsg::ExitSignal { .. }) => {
                                return Err(RemoteError::RemoteFailure);
                            }
                            Some(russh::ChannelMsg::Close) | None => break,
                            _ => {}
                        }
                    }
                    match exit_status {
                        Some(72) => return Err(RemoteError::Unsupported),
                        Some(73) => return Err(RemoteError::PermissionDenied),
                        Some(0) if accepted => {}
                        Some(_) => return Err(RemoteError::RemoteFailure),
                        None => return Err(RemoteError::ConnectionLost),
                    }
                    let text =
                        std::str::from_utf8(&output).map_err(|_| RemoteError::MalformedData)?;
                    let current = parse_linux_sample(text)?;
                    let now = Instant::now();
                    let metrics =
                        current.metrics(previous.as_ref().map(|(time, sample)| {
                            (sample, now.duration_since(*time).as_secs_f64())
                        }));
                    *previous = Some((now, current));
                    Ok(metrics)
                },
            )
            .await
        })
        .await
    }
}

pub fn parse_linux_sample(input: &str) -> Result<LinuxSample, RemoteError> {
    if input.len() > 256 * 1024 {
        return Err(RemoteError::OutputLimit);
    }
    let labels = [
        "SYSTEM", "STAT", "MEMORY", "NETWORK", "UPTIME", "DISK", "END",
    ];
    let mut remainder = input
        .strip_prefix("__CONNDOCK_SYSTEM__\n")
        .ok_or(RemoteError::MalformedData)?;
    let mut sections = Vec::with_capacity(6);
    for label in &labels[1..] {
        let marker = format!("__CONNDOCK_{label}__\n");
        let (value, rest) = remainder
            .split_once(&marker)
            .ok_or(RemoteError::MalformedData)?;
        sections.push(value.trim());
        remainder = rest;
    }
    if !remainder.trim().is_empty() || !sections[0].starts_with("Linux ") || sections[0].len() > 256
    {
        return Err(RemoteError::MalformedData);
    }
    let cpu_line = sections[1]
        .lines()
        .find(|line| line.starts_with("cpu "))
        .ok_or(RemoteError::MalformedData)?;
    let ticks = cpu_line
        .split_whitespace()
        .skip(1)
        .take(8)
        .map(number)
        .collect::<Result<Vec<_>, _>>()?;
    let cpu: [u64; 8] = ticks.try_into().map_err(|_| RemoteError::MalformedData)?;
    let mut memory = BTreeMap::new();
    for line in sections[2].lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let mut parts = value.split_whitespace();
        if let (Some(value), Some("kB")) = (parts.next(), parts.next()) {
            memory.insert(
                key,
                number(value)?
                    .checked_mul(1024)
                    .ok_or(RemoteError::MalformedData)?,
            );
        }
    }
    let memory_total = *memory.get("MemTotal").ok_or(RemoteError::MalformedData)?;
    let memory_available = if let Some(value) = memory.get("MemAvailable") {
        *value
    } else {
        ["MemFree", "Buffers", "Cached", "SReclaimable"]
            .iter()
            .try_fold(0_u64, |sum, key| {
                sum.checked_add(*memory.get(key).unwrap_or(&0))
            })
            .ok_or(RemoteError::MalformedData)?
            .saturating_sub(*memory.get("Shmem").unwrap_or(&0))
            .min(memory_total)
    };
    if memory_total == 0 || memory_available > memory_total {
        return Err(RemoteError::MalformedData);
    }
    let uptime_seconds = sections[4]
        .split_whitespace()
        .next()
        .ok_or(RemoteError::MalformedData)?
        .parse::<f64>()
        .map_err(|_| RemoteError::MalformedData)?;
    if !uptime_seconds.is_finite() || uptime_seconds < 0.0 {
        return Err(RemoteError::MalformedData);
    }
    let disk = sections[5]
        .lines()
        .last()
        .ok_or(RemoteError::MalformedData)?
        .split_whitespace()
        .collect::<Vec<_>>();
    if disk.len() < 6 {
        return Err(RemoteError::MalformedData);
    }
    let bytes = |s| {
        number(s)?
            .checked_mul(1024)
            .ok_or(RemoteError::MalformedData)
    };
    let (disk_total, disk_used, disk_available) =
        (bytes(disk[1])?, bytes(disk[2])?, bytes(disk[3])?);
    let disk_percent = number(
        disk[4]
            .strip_suffix('%')
            .ok_or(RemoteError::MalformedData)?,
    )? as f64;
    if disk_total == 0
        || disk_used > disk_total
        || disk_available > disk_total
        || disk_percent > 100.0
    {
        return Err(RemoteError::MalformedData);
    }
    let mut interfaces = BTreeMap::new();
    for line in sections[3].lines() {
        let Some((name, data)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty()
            || name.len() > 128
            || name.chars().any(char::is_control)
            || interfaces.len() >= 1024
        {
            return Err(RemoteError::MalformedData);
        }
        let fields = data.split_whitespace().collect::<Vec<_>>();
        if fields.len() < 16 {
            return Err(RemoteError::MalformedData);
        }
        if name != "lo"
            && interfaces
                .insert(name.to_owned(), (number(fields[0])?, number(fields[8])?))
                .is_some()
        {
            return Err(RemoteError::MalformedData);
        }
    }
    Ok(LinuxSample {
        system: sections[0].to_owned(),
        uptime_seconds,
        memory_total,
        memory_available,
        disk_total,
        disk_used,
        disk_available,
        disk_percent,
        cpu,
        interfaces,
    })
}

fn number(text: &str) -> Result<u64, RemoteError> {
    text.parse().map_err(|_| RemoteError::MalformedData)
}

impl LinuxSample {
    pub fn metrics(&self, previous: Option<(&Self, f64)>) -> LinuxMetrics {
        let mut metrics = LinuxMetrics {
            system: self.system.clone(),
            uptime_seconds: self.uptime_seconds,
            cpu_percent: None,
            memory_total: self.memory_total,
            memory_used: self.memory_total.saturating_sub(self.memory_available),
            disk_total: self.disk_total,
            disk_used: self.disk_used,
            disk_percent: self.disk_percent,
            receive_bytes_per_second: None,
            transmit_bytes_per_second: None,
        };
        if let Some((before, seconds)) =
            previous.filter(|(_, secs)| secs.is_finite() && *secs > 0.0 && *secs <= 300.0)
        {
            let deltas = self
                .cpu
                .iter()
                .zip(before.cpu)
                .map(|(new, old)| new.checked_sub(old))
                .collect::<Option<Vec<_>>>();
            if let Some(deltas) = deltas {
                let total: u128 = deltas.iter().map(|v| *v as u128).sum();
                let idle = deltas[3] as u128 + deltas[4] as u128;
                if total > 0 {
                    metrics.cpu_percent =
                        Some(((total - idle) as f64 / total as f64 * 100.0).clamp(0.0, 100.0));
                }
            }
            let mut network = Vec::new();
            for (name, (rx, tx)) in &self.interfaces {
                if let Some((old_rx, old_tx)) = before.interfaces.get(name)
                    && let (Some(rx), Some(tx)) = (rx.checked_sub(*old_rx), tx.checked_sub(*old_tx))
                {
                    network.push((rx, tx));
                }
            }
            if !network.is_empty() {
                metrics.receive_bytes_per_second =
                    Some(network.iter().map(|(rx, _)| *rx as f64).sum::<f64>() / seconds);
                metrics.transmit_bytes_per_second =
                    Some(network.iter().map(|(_, tx)| *tx as f64).sum::<f64>() / seconds);
            }
        }
        metrics
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(cpu: &str, rx: u64, tx: u64) -> String {
        format!(
            "__CONNDOCK_SYSTEM__\nLinux 6.8.0\n__CONNDOCK_STAT__\ncpu {cpu}\ncpu0 0 0 0 0 0 0 0 0\n__CONNDOCK_MEMORY__\nMemTotal: 8192 kB\nMemFree: 1024 kB\nMemAvailable: 3072 kB\nBuffers: 128 kB\nCached: 512 kB\n__CONNDOCK_NETWORK__\nInter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\nlo: 50 0 0 0 0 0 0 0 50 0 0 0 0 0 0 0\neth0: {rx} 0 0 0 0 0 0 0 {tx} 0 0 0 0 0 0 0\n__CONNDOCK_UPTIME__\n123.5 33.0\n__CONNDOCK_DISK__\nFilesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda 1000 400 550 43% /\n__CONNDOCK_END__\n"
        )
    }

    #[test]
    fn parses_real_proc_shapes_and_defers_rates_until_a_second_sample() {
        let sample = parse_linux_sample(&fixture("100 10 20 400 10 2 3 5 90 0", 100, 200)).unwrap();
        let metrics = sample.metrics(None);
        assert_eq!(metrics.system, "Linux 6.8.0");
        assert_eq!(metrics.memory_total, 8192 * 1024);
        assert_eq!(metrics.memory_used, 5120 * 1024);
        assert_eq!(metrics.disk_percent, 43.0);
        assert_eq!(metrics.uptime_seconds, 123.5);
        assert_eq!(metrics.cpu_percent, None);
        assert_eq!(metrics.receive_bytes_per_second, None);
        assert!(!sample.interfaces.contains_key("lo"));
    }

    #[test]
    fn cpu_excludes_guest_and_rates_use_elapsed_time() {
        let before = parse_linux_sample(&fixture("100 10 20 400 10 2 3 5 90 0", 100, 200)).unwrap();
        let after =
            parse_linux_sample(&fixture("130 10 30 450 20 2 3 5 120 0", 1124, 712)).unwrap();
        let metrics = after.metrics(Some((&before, 2.0)));
        assert_eq!(metrics.cpu_percent, Some(40.0));
        assert_eq!(metrics.receive_bytes_per_second, Some(512.0));
        assert_eq!(metrics.transmit_bytes_per_second, Some(256.0));
    }

    #[test]
    fn counter_reset_and_new_interfaces_do_not_create_spikes() {
        let before = parse_linux_sample(&fixture("100 10 20 400 10 2 3 5", 100, 200)).unwrap();
        let mut after = parse_linux_sample(&fixture("1 0 0 4 0 0 0 0", 2, 3)).unwrap();
        after.interfaces.insert("new0".into(), (u64::MAX, u64::MAX));
        let metrics = after.metrics(Some((&before, 5.0)));
        assert_eq!(metrics.cpu_percent, None);
        assert_eq!(metrics.receive_bytes_per_second, None);
    }

    #[test]
    fn rejects_incomplete_invalid_and_oversized_samples() {
        for text in [
            String::new(),
            fixture("100 10 20 400 10 2 3 5", 1, 2).replace("8192", "bad"),
            fixture("100 10 20 400 10 2 3 5", 1, 2).replace("__CONNDOCK_END__", ""),
            "x".repeat(256 * 1024 + 1),
        ] {
            assert!(parse_linux_sample(&text).is_err());
        }
    }
}
