import subprocess
import os
import time

adb = r"C:\Users\deanc\platform-tools\adb.exe"
device = "R5CW21C5WHB"
dst = "/data/adb/modules/rmg_memtonic"

def run_adb(args):
    return subprocess.run([adb, "-s", device] + args, capture_output=True, text=True)

def run_su(cmd_text):
    local_tmp = r"D:\Codex\s9180-rootmygalaxy\modules\rmg_memtonic\tests\_test_tmp.sh"
    with open(local_tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(cmd_text)
    run_adb(["push", local_tmp, "/data/local/tmp/_test_tmp.sh"])
    res = run_adb(["shell", "su -c 'sh /data/local/tmp/_test_tmp.sh && rm -f /data/local/tmp/_test_tmp.sh'"])
    if os.path.exists(local_tmp):
        os.remove(local_tmp)
    return res.stdout, res.stderr

print("=== Starting 3-minute (180s) steady-state observation ===")
script_initial = f"""#!/system/bin/sh
. {dst}/scripts/mt_lib.sh
m_pid=$(cat {dst}/run/memtonic.pid 2>/dev/null); m_pid=${{m_pid%%:*}}
f_pid=$(cat {dst}/run/fluencyshield.pid 2>/dev/null); f_pid=${{f_pid%%:*}}
echo "Initial: memtonic_pid=$m_pid cpu_ms=$(self_cpu_ms $m_pid)"
echo "Initial: fluency_pid=$f_pid cpu_ms=$(self_cpu_ms $f_pid)"
echo "Initial: top_app=$(get_top_app_info)"
"""
out, _ = run_su(script_initial)
print(out.strip())

# Sample every 30 seconds for 180 seconds (6 samples)
for i in range(1, 7):
    time.sleep(30)
    script_sample = f"""#!/system/bin/sh
. {dst}/scripts/mt_lib.sh
m_pid=$(cat {dst}/run/memtonic.pid 2>/dev/null); m_pid=${{m_pid%%:*}}
f_pid=$(cat {dst}/run/fluencyshield.pid 2>/dev/null); f_pid=${{f_pid%%:*}}
echo "T+{i*30}s: memtonic(pid $m_pid) cpu_ms=$(self_cpu_ms $m_pid) | fluency(pid $f_pid) cpu_ms=$(self_cpu_ms $f_pid) | top_app=$(get_top_app_info)"
"""
    out, _ = run_su(script_sample)
    print(out.strip())

print("\n=== Final post-observation verification ===")
script_final = f"""#!/system/bin/sh
. {dst}/scripts/mt_lib.sh
echo "=== LOG TAIL ==="
tail -n 15 {dst}/run/memtonic.log

echo "=== DESCRIPTION ==="
grep "^description=" {dst}/module.prop

echo "=== KSU MODULE LIST ==="
ksud module list | grep -E '("id": "rmg_memtonic"|"version":|"versionCode":)'

echo "=== LINE COUNTS OF SCRIPTS ON DEVICE ==="
wc -l {dst}/scripts/*.sh
"""
out, _ = run_su(script_final)
print(out)
