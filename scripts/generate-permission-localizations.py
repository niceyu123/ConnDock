#!/usr/bin/env python3
"""Generate native InfoPlist.strings from the canonical String Catalog."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parents[1] / 'apple/Resources/Localizable.xcstrings')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    try:
        catalog = json.loads(args.catalog.read_text(encoding='utf-8'))
        localizations = catalog['strings']['NSLocalNetworkUsageDescription']['localizations']
        outputs = []
        for language in ['zh-Hans', 'en']:
            unit = localizations[language]['stringUnit']
            if unit['state'] != 'translated' or not unit['value'].strip():
                raise ValueError('Permission translation is incomplete')
            target = args.output / (language + '.lproj/InfoPlist.strings')
            value = '"NSLocalNetworkUsageDescription" = ' + json.dumps(unit['value'], ensure_ascii=False) + ';\n'
            if target.exists() and not args.force and target.read_text(encoding='utf-8') != value:
                raise ValueError('Refusing to overwrite permission resources without --force')
            outputs.append((target, value))
        for target, value in outputs:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value, encoding='utf-8')
        print('Generated native permission strings: zh-Hans/en')
        return 0
    except (OSError, ValueError, KeyError, TypeError):
        print('Permission resources failed: check reviewed translations and output path')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
