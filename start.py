"""
Lumi-Hub 2.0 一键启动脚本
同时启动 Host (WebSocket Server) 和 Flutter 客户端。

用法:
    python start.py              # 默认启动 Windows Flutter 客户端
    python start.py --android    # 启动 Android 客户端
    python start.py --host-only  # 只启动 Host
"""
import subprocess
import sys
import os
import signal
import time
import argparse
import shutil


def find_flutter():
    """查找 Flutter 可执行文件。"""
    flutter = shutil.which("flutter") or shutil.which("flutter.bat")
    return flutter or "flutter"


def main():
    parser = argparse.ArgumentParser(description="Lumi-Hub 2.0 Launcher")
    parser.add_argument("--android", action="store_true", help="Launch Android client")
    parser.add_argument("--host-only", action="store_true", help="Only start host server")
    parser.add_argument("--flutter-only", action="store_true", help="Only start Flutter client")
    parser.add_argument("--device", type=str, default=None, help="Flutter device ID")
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.abspath(__file__))
    client_dir = os.path.join(project_root, "client")
    processes = []

    def cleanup(sig=None, frame=None):
        print("\n[Launcher] Shutting down...")
        for p in processes:
            try:
                p.terminate()
            except Exception:
                pass
        for p in processes:
            try:
                p.wait(timeout=5)
            except Exception:
                p.kill()
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    # 启动 Host
    if not args.flutter_only:
        print("[Launcher] Starting Host...")
        host_process = subprocess.Popen(
            [sys.executable, "-m", "host.main"],
            cwd=project_root,
            stdout=sys.stdout,
            stderr=sys.stderr,
        )
        processes.append(host_process)
        print(f"[Launcher] Host started (PID: {host_process.pid})")
        time.sleep(2)

    # 启动 Flutter
    if not args.host_only:
        flutter = find_flutter()
        print(f"[Launcher] Starting Flutter...")
        flutter_cmd = [flutter, "run"]
        if args.device:
            flutter_cmd.extend(["-d", args.device])
        elif args.android:
            flutter_cmd.extend(["-d", "android"])

        flutter_process = subprocess.Popen(
            flutter_cmd,
            cwd=client_dir,
            stdout=sys.stdout,
            stderr=sys.stderr,
        )
        processes.append(flutter_process)
        print(f"[Launcher] Flutter started (PID: {flutter_process.pid})")

    if not processes:
        print("[Launcher] Nothing to start.")
        return

    try:
        while processes:
            for p in processes[:]:
                if p.poll() is not None:
                    processes.remove(p)
            if processes:
                time.sleep(1)
    except KeyboardInterrupt:
        cleanup()


if __name__ == "__main__":
    main()
