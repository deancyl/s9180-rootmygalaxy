#!/usr/bin/env python3
"""Build a RootMyGalaxy 0.2.36 variant with embedded KernelSU v3.3.0 ksud.

Takes the VERIFIED base APK (rootmygalaxy-0.2.36-base.apk, md5 3b334cda...)
and replaces ONLY:
  - assets/ksud-f731u-kdp  -> our v3.3.0 ephemeral-capable ksud
    (md5 1e909d3f60f77c2739d079f80ad33724, 4,996,008 B, real KSU 32601,
     device-verified late-load on 2026-09-21)
  - assets/targets-v3.json -> kernelsu.size updated to the new ksud size
Everything else (payload cve-2026-43499-app.so, libcve43499root.so, dex,
resources) is copied verbatim from the verified base.
Output: unsigned APK, then re-sign with uber-apk-signer.
"""
import sys, zipfile, json, os

def main(base_apk, ksud330, out_apk):
    ksud_data = open(ksud330, 'rb').read()
    with zipfile.ZipFile(base_apk, 'r') as src:
        orig = src.read('assets/targets-v3.json')
        feed = json.loads(orig)
        assert feed['payloads'][0]['kernelsu']['size'] == 6756208, \
            f"unexpected base feed size: {feed['payloads'][0]['kernelsu']['size']}"
        feed['payloads'][0]['kernelsu']['size'] = len(ksud_data)
        new_feed = json.dumps(feed, indent=2).encode()
        # sanity: confirm what base embeds (should match SAMPLE.md)
        print('base ksud md5 check:')
        import hashlib
        old = src.read('assets/ksud-f731u-kdp')
        print('  old:', hashlib.md5(old).hexdigest(), len(old), 'B')
        print('  new:', hashlib.md5(ksud_data).hexdigest(), len(ksud_data), 'B')

        with zipfile.ZipFile(out_apk, 'w') as dst:
            for item in src.infolist():
                name = item.filename
                if name == 'assets/ksud-f731u-kdp':
                    zi = zipfile.ZipInfo(name, date_time=item.date_time)
                    zi.compress_type = item.compress_type
                    zi.external_attr = item.external_attr
                    dst.writestr(zi, ksud_data)
                    print(f'  replaced {name} ({len(ksud_data)} B, KSU v3.3.0 ksud)')
                    continue
                if name == 'assets/targets-v3.json':
                    zi = zipfile.ZipInfo(name, date_time=item.date_time)
                    zi.compress_type = item.compress_type
                    zi.external_attr = item.external_attr
                    dst.writestr(zi, new_feed)
                    print(f'  replaced {name} (kernelsu.size -> {len(ksud_data)})')
                    continue
                data = src.read(name)
                ni = zipfile.ZipInfo(name, date_time=item.date_time)
                ni.compress_type = item.compress_type
                ni.external_attr = item.external_attr
                dst.writestr(ni, data)
    print(f'\nunsigned APK written: {out_apk} ({os.path.getsize(out_apk)} B)')

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print('usage: build_ksu330_apk.py <base.apk> <ksud-330> <out-unsigned.apk>')
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
