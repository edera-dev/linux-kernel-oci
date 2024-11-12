import json
import os
from pathlib import Path

docker_daemon_path = Path("/etc/docker/daemon.json")
if not docker_daemon_path.exists():
    if not docker_daemon_path.parent.exists():
        docker_daemon_path.parent.mkdir()

    docker_daemon_path.write_text("{}\n")
docker_daemon_json = json.loads(docker_daemon_path.read_text())
if "features" not in docker_daemon_json:
    docker_daemon_json["features"] = {}

docker_daemon_json["features"]["containerd-snapshotter"] = True

docker_daemon_text = json.dumps(docker_daemon_json, indent=4)
docker_daemon_text += "\n"
docker_daemon_path.write_text(docker_daemon_text)

os.execve("/usr/bin/systemctl", ["systemctl", "restart", "docker"], env=os.environ)
