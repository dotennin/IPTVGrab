#!/usr/bin/env python3
"""Start the M3U8 Downloader web server."""
import subprocess
import sys

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"Starting M3U8 Downloader at http://localhost:{port}")
    subprocess.run(
        [
            sys.executable, "-m", "uvicorn", "main:app",
            "--host", "0.0.0.0",
            "--port", str(port),
            "--reload",
        ]
    )
