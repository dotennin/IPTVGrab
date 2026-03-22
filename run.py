#!/usr/bin/env python3
"""Start the IPTVGrab web server."""
import argparse
import os
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(
        description="IPTVGrab – M3U8 & IPTV download server",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--port", "-p",
        type=int,
        default=int(os.environ.get("PORT", 8765)),
        help="TCP port to listen on",
    )
    parser.add_argument(
        "--downloads-dir", "-d",
        default=os.environ.get("DOWNLOADS_DIR", "downloads"),
        metavar="PATH",
        help="Directory where finished MP4 files are saved",
    )
    parser.add_argument(
        "--host",
        default="0.0.0.0",
        help="Host/IP to bind",
    )
    parser.add_argument(
        "--dev",
        action="store_true",
        help="Enable uvicorn --reload for development",
    )
    args = parser.parse_args()

    env = os.environ.copy()
    env["DOWNLOADS_DIR"] = args.downloads_dir

    print(f"  IPTVGrab  →  http://{args.host}:{args.port}")
    print(f"  Downloads dir    →  {args.downloads_dir}")

    cmd = [
        sys.executable, "-m", "uvicorn", "main:app",
        "--host", args.host,
        "--port", str(args.port),
    ]
    if args.dev:
        cmd.append("--reload")

    subprocess.run(cmd, env=env)


if __name__ == "__main__":
    main()
