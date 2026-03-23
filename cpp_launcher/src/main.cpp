#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include "env_checker.h"

#pragma comment(lib, "ws2_32.lib")

namespace {
    constexpr int kHostPort = 8765;

    std::string readEnvOrDefault(const char* key, const char* fallback) {
        char* value = nullptr;
        size_t len = 0;
        if (_dupenv_s(&value, &len, key) != 0 || value == nullptr || len == 0) {
            return fallback;
        }
        std::string result(value);
        free(value);
        if (result.empty()) {
            return fallback;
        }
        return result;
    }

    bool isPortConnectable(const std::string& host, int port, int timeoutMs) {
        WSADATA wsaData;
        if (WSAStartup(MAKEWORD(2, 2), &wsaData) != NO_ERROR) {
            return false;
        }

        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) {
            WSACleanup();
            return false;
        }

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<u_short>(port));
        inet_pton(AF_INET, host.c_str(), &addr.sin_addr);

        u_long mode = 1;
        ioctlsocket(sock, FIONBIO, &mode);

        int result = connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
        if (result == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) {
            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(sock, &writeSet);

            timeval timeout{};
            timeout.tv_sec = timeoutMs / 1000;
            timeout.tv_usec = (timeoutMs % 1000) * 1000;

            result = select(0, nullptr, &writeSet, nullptr, &timeout);
            if (result > 0) {
                int socketError = 0;
                int len = sizeof(socketError);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&socketError), &len);
                closesocket(sock);
                WSACleanup();
                return socketError == 0;
            }
        }

        bool ok = (result == 0);
        closesocket(sock);
        WSACleanup();
        return ok;
    }

    bool waitForPortReady(const std::string& host, int port, int timeoutSec) {
        auto start = std::chrono::steady_clock::now();
        while (true) {
            if (isPortConnectable(host, port, 300)) {
                return true;
            }

            auto now = std::chrono::steady_clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - start).count();
            if (elapsed >= timeoutSec) {
                return false;
            }

            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
    }

    bool launchByCmd(const std::string& command, bool newConsole, PROCESS_INFORMATION& pi) {
        STARTUPINFOA si{};
        si.cb = sizeof(si);

        ZeroMemory(&pi, sizeof(pi));

        std::string cmdLine = "cmd.exe /c \"" + command + "\"";
        DWORD creationFlags = newConsole ? CREATE_NEW_CONSOLE : 0;

        BOOL created = CreateProcessA(
            nullptr,
            cmdLine.data(),
            nullptr,
            nullptr,
            FALSE,
            creationFlags,
            nullptr,
            nullptr,
            &si,
            &pi
        );

        return created == TRUE;
    }
}

int main() {
    SetConsoleOutputCP(CP_UTF8);

    std::string astrbotRoot = readEnvOrDefault("LUMI_ASTRBOT_ROOT", "D:\\astrbot-develop\\AstrBot");
    std::string clientDir = readEnvOrDefault("LUMI_CLIENT_DIR", "E:\\Lumi-Hub\\client");
    std::string clientMode = readEnvOrDefault("LUMI_CLIENT_MODE", "flutter_run");
    std::string clientExePath = readEnvOrDefault("LUMI_CLIENT_EXE", "");

    std::cout << "=====================================================\n";
    std::cout << "Lumi-Hub C++ Native Launcher (Phase 13 - M1)\n";
    std::cout << "=====================================================\n";
    std::cout << "[配置] AstrBot 路径: " << astrbotRoot << "\n";
    std::cout << "[配置] Client 模式: " << clientMode << "\n";
    std::cout << "[配置] Client 路径: " << clientDir << "\n\n";

    std::cout << "[1/4] 环境检查中...\n";
    if (!LumiHub::EnvChecker::isPythonAvailable()) {
        std::cout << "  [失败] 未检测到全局 Python（请确认 python 在 PATH 中）。\n";
        system("pause");
        return 1;
    }
    std::cout << "  [通过] Python 环境可用。\n";

    const bool portFree = LumiHub::EnvChecker::isPortAvailable(kHostPort);
    const bool hostAlreadyReady = !portFree && isPortConnectable("127.0.0.1", kHostPort, 600);

    std::cout << "[2/4] AstrBot Host 检测与启动...\n";
    if (hostAlreadyReady) {
        std::cout << "  [复用] 检测到 127.0.0.1:" << kHostPort << " 已在线，跳过 AstrBot 拉起。\n";
    } else if (!portFree) {
        std::cout << "  [失败] 端口 " << kHostPort << " 被占用，但无法连通到 Lumi Host，疑似冲突。\n";
        std::cout << "  请先释放端口后重试。\n";
        system("pause");
        return 1;
    } else {
        PROCESS_INFORMATION hostPi{};
        const std::string astrbotCmd = "cd /d \"" + astrbotRoot + "\" && python main.py";
        std::cout << "  [执行] " << astrbotCmd << "\n";
        if (!launchByCmd(astrbotCmd, true, hostPi)) {
            std::cout << "  [失败] 无法启动 AstrBot 进程，GetLastError=" << GetLastError() << "\n";
            system("pause");
            return 1;
        }

        CloseHandle(hostPi.hThread);
        CloseHandle(hostPi.hProcess);
        std::cout << "  [通过] AstrBot 拉起指令已发出，等待 Host 端口就绪...\n";

        if (!waitForPortReady("127.0.0.1", kHostPort, 40)) {
            std::cout << "  [失败] 等待 127.0.0.1:" << kHostPort << " 超时（40s）。\n";
            system("pause");
            return 1;
        }
    }

    std::cout << "[3/4] Host 连通性检查...\n";
    if (!waitForPortReady("127.0.0.1", kHostPort, 5)) {
        std::cout << "  [失败] Host 端口不可达，请检查 AstrBot 日志。\n";
        system("pause");
        return 1;
    }
    std::cout << "  [通过] Lumi Host 已就绪。\n";

    std::cout << "[4/4] 启动 Client...\n";
    PROCESS_INFORMATION clientPi{};
    bool clientStarted = false;
    if (clientMode == "flutter_run") {
        const std::string flutterCmd = "cd /d \"" + clientDir + "\" && flutter run -d windows";
        std::cout << "  [执行] " << flutterCmd << "\n";
        clientStarted = launchByCmd(flutterCmd, true, clientPi);
    } else if (clientMode == "exe" && !clientExePath.empty()) {
        const std::string exeCmd = "\"" + clientExePath + "\"";
        std::cout << "  [执行] " << exeCmd << "\n";
        clientStarted = launchByCmd(exeCmd, true, clientPi);
    } else {
        std::cout << "  [失败] Client 模式无效。请设置 LUMI_CLIENT_MODE=flutter_run 或 exe。\n";
    }

    if (!clientStarted) {
        std::cout << "  [失败] Client 启动失败，GetLastError=" << GetLastError() << "\n";
        system("pause");
        return 1;
    }

    CloseHandle(clientPi.hThread);
    CloseHandle(clientPi.hProcess);

    std::cout << "\n全部流程完成：AstrBot 与 Client 启动指令均已发出。\n";
    std::cout << "提示：可通过环境变量调整路径与模式：\n";
    std::cout << "  LUMI_ASTRBOT_ROOT / LUMI_CLIENT_DIR / LUMI_CLIENT_MODE / LUMI_CLIENT_EXE\n";
    system("pause");
    return 0;
}
