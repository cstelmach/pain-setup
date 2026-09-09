"""Run: python3 verify-interaction-export.py. Fake Docker only; never contacts the real stack."""
import csv
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent
HEADER = "id,received_at,userid,tabid,seq,event_type,target,action,country,emotion,enabled,layer,step,count,selected_count,has_text,characters,duration_ms,survey_consent,occurred_at"

with tempfile.TemporaryDirectory(prefix="pain-export-test-") as temporary:
    folder = Path(temporary)
    fake_bin = folder / "fake bin"
    fake_bin.mkdir()
    docker = fake_bin / "docker"
    docker.write_text("""#!/usr/bin/env python3
import json, os, subprocess, sys
if sys.argv[1] == 'compose':
    assert sys.argv[2] == '-f' and sys.argv[-3:] == ['ps', '-q', 'pain-db']
    print('abc123')
elif sys.argv[1:4] == ['exec', '-i', 'abc123']:
    query = sys.stdin.read()
    assert 'READ ONLY' in query and 'REPEATABLE READ' in query
    assert 'SELECT *' not in query and 'FROM interactionevents' in query
    assert all(name not in query for name in ['FROM users', 'FROM answers', 'FROM metrics', 'DELETE ', 'UPDATE '])
    if os.environ.get('PAIN_EXPORT_TEST_FAIL'):
        print('synthetic database export failure', file=sys.stderr)
        sys.exit(7)
    if os.environ.get('PAIN_EXPORT_TEST_PSQL'):
        sys.exit(subprocess.run([os.environ['PAIN_EXPORT_TEST_PSQL'], '-X', '-q', '-A', '-t',
            '--set=ON_ERROR_STOP=1', '-h', '127.0.0.1', '-p', '55439', '-U', 'cs',
            '-d', 'pain_analytics_test_2'], input=query, text=True).returncode)
    print(os.environ['PAIN_EXPORT_TEST_HEADER'])
    for n in range(20000):
        print(f'{n},2026-09-09 12:00:00+00,1,12345678-1234-4123-8123-123456789abc,{n},country,country,open,GRL,,t,all-layers,,,,,,,f,2026-09-09 11:59:55+00')
    print(json.dumps({'events': 20000, 'users': 1, 'tabs': 1}), file=sys.stderr)
else:
    raise AssertionError(sys.argv)
""")
    docker.chmod(0o755)
    compose = folder / "compose file.yml"
    compose.write_text("services: {}\n")
    env = {**os.environ, "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
           "PAIN_EXPORT_TEST_HEADER": HEADER}
    expected = 4000 if env.get("PAIN_EXPORT_TEST_PSQL") else 20000
    commands = [["bash", str(ROOT / "export-interactions.sh")]]
    if shutil.which("pwsh"):
        commands.append(["pwsh", "-NoProfile", "-File", str(ROOT / "export-interactions.ps1")])
    for index, command in enumerate(commands):
        output = folder / f"export output {index}"
        args = [str(output), str(compose)]
        if command[0] == "pwsh":
            args = ["-OutputDirectory", str(output), "-ComposeFile", str(compose)]
        completed = subprocess.run(command + args, env=env, cwd="/tmp", capture_output=True, text=True)
        assert completed.returncode == 0, completed.stdout + completed.stderr
        archives = list(output.glob("*.zip"))
        assert len(archives) == 1 and len(list(output.iterdir())) == 1
        with zipfile.ZipFile(archives[0]) as archive:
            assert set(archive.namelist()) == {"interaction-events.csv", "summary.json", "data-dictionary.txt"}
            with archive.open("interaction-events.csv") as stream:
                reader = csv.reader(io.TextIOWrapper(stream, encoding="utf-8"))
                assert next(reader) == HEADER.split(",")
                rows = list(reader)
                assert len(rows) == expected
                assert all(len(row) == len(HEADER.split(',')) for row in rows)
            assert json.loads(archive.read("summary.json"))["events"] == expected
        failed = subprocess.run(command + args, env={**env, "PAIN_EXPORT_TEST_FAIL": "1"},
                                cwd="/tmp", capture_output=True, text=True)
        assert failed.returncode != 0
        assert len(list(output.glob("*.zip"))) == 1, "Failure must not produce a successful-looking ZIP"
    print(json.dumps({"passed": True, "platform_scripts": len(commands), "rows_per_export": expected}))
