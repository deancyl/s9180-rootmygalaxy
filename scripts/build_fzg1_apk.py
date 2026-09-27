#!/usr/bin/env python3
"""APK surgery: take soumarcelino S918B release APK, replace the embedded
exploit payload with our FZG1 version, update targets-v3.json to declare
SM-S9180 FZG1, and strip the old signature. Output: unsigned APK ready for
uber-apk-signer to re-sign with a debug key."""
import sys, zipfile, json, shutil, os

def main(base_apk, fzg1_payload, f731u_helper, out_apk):
    new_targets = {
        "schemaVersion": 3,
        "payloads": [{
            "payloadId": "dm3q-S9180ZHS8FZG1",
            "displayName": "Galaxy S23 Ultra SM-S9180 | S9180ZHS8FZG1 (FZG1)",
            "models": ["SM-S9180"],
            "kernelVersions": ["5.15.189"],
            "exploit": {"url": "asset://cve-2026-43499-app.so", "size": 131072},
            "kernelsu": {"url": "asset://ksud-f731u-kdp", "size": 6756208}
        }]
    }
    new_targets_bytes = json.dumps(new_targets, indent=2).encode()
    helper_data = open(f731u_helper, 'rb').read()

    with zipfile.ZipFile(base_apk, 'r') as src:
        with zipfile.ZipFile(out_apk, 'w') as dst:
            for item in src.infolist():
                name = item.filename
                # strip any v1 signature files (none in this APK but be safe)
                if name.startswith('META-INF/') and (
                    name.endswith('.SF') or name.endswith('.RSA') or
                    name.endswith('.DSA') or name.endswith('.MF') or
                    name.endswith('.EC')):
                    continue
                # replace payload (FZG1)
                if name == 'assets/cve-2026-43499-app.so':
                    data = open(fzg1_payload, 'rb').read()
                    zi = zipfile.ZipInfo(name, date_time=(2026,8,19,10,0,0))
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    dst.writestr(zi, data)
                    print(f'  replaced {name} ({len(data)} bytes, FZG1 payload)')
                    continue
                # replace helper (f731u verified version)
                if name == 'lib/arm64-v8a/libcve43499root.so':
                    zi = zipfile.ZipInfo(name, date_time=(2026,8,19,10,0,0))
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    dst.writestr(zi, helper_data)
                    print(f'  replaced {name} ({len(helper_data)} bytes, f731u helper)')
                    continue
                # replace targets feed
                if name == 'assets/targets-v3.json':
                    zi = zipfile.ZipInfo(name, date_time=(2026,8,19,10,0,0))
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    dst.writestr(zi, new_targets_bytes)
                    print(f'  replaced {name} (SM-S9180 FZG1 feed)')
                    continue
                # copy everything else verbatim, preserving compression
                data = src.read(name)
                ni = zipfile.ZipInfo(name, date_time=item.date_time)
                ni.compress_type = item.compress_type
                ni.external_attr = item.external_attr
                dst.writestr(ni, data)
    print(f'\nunsigned APK written: {out_apk} ({os.path.getsize(out_apk)} bytes)')

if __name__ == '__main__':
    if len(sys.argv) != 5:
        print('usage: build_fzg1_apk.py <base.apk> <fzg1-payload.so> <f731u-helper.so> <out-unsigned.apk>')
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
