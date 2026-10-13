#!/usr/bin/python3
"""Minimal localhost Prometheus exporter for Slurm controller/node health."""

import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def metrics():
    ping = subprocess.run(
        ["scontrol", "ping"], capture_output=True, text=True, timeout=10, check=False
    )
    lines = ["# HELP cluster_slurmctld_up 1 when scontrol ping succeeds.",
             "# TYPE cluster_slurmctld_up gauge",
             f"cluster_slurmctld_up {1 if ping.returncode == 0 and 'is UP' in ping.stdout else 0}",
             "# HELP cluster_slurm_node_unavailable 1 when a node is down or drained.",
             "# TYPE cluster_slurm_node_unavailable gauge"]
    nodes = subprocess.run(
        ["sinfo", "--noheader", "--Node", "--format=%N|%T"],
        capture_output=True, text=True, timeout=10, check=False
    )
    if nodes.returncode == 0:
        for row in nodes.stdout.splitlines():
            hostname, _, state = row.strip().partition("|")
            state = state.rstrip("*~#+")
            unavailable = state.startswith(("down", "drain"))
            lines.append(
                f'cluster_slurm_node_unavailable{{hostname="{hostname}",state="{state}"}} '
                f'{1 if unavailable else 0}')
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 9817), Handler).serve_forever()
