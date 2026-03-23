#include "env_checker.h"
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iostream>

#pragma comment(lib, "ws2_32.lib")

namespace LumiHub {

    bool EnvChecker::isPythonAvailable() {
        // 通过调用系统命令 python --version 并捕获输出来判断
        FILE* pipe = _popen("python --version 2>&1", "r");
        if (!pipe) {
            return false;
        }
        
        char buffer[128];
        std::string result = "";
        while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
            result += buffer;
        }
        int returnCode = _pclose(pipe);
        
        // 如果返回值是 0，说明成功执行了 python 命令并获取到了版本信息
        return (returnCode == 0);
    }

    bool EnvChecker::isPortAvailable(int port) {
        WSADATA wsaData;
        int iResult = WSAStartup(MAKEWORD(2, 2), &wsaData);
        if (iResult != NO_ERROR) {
            std::cerr << "WSAStartup 失败: " << iResult << std::endl;
            return false; // 初始化失败为了安全起见假设端口不可用
        }

        SOCKET ListenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (ListenSocket == INVALID_SOCKET) {
            WSACleanup();
            return false;
        }

        sockaddr_in service;
        service.sin_family = AF_INET;
        // 使用 inet_pton 替代过时的 inet_addr
        inet_pton(AF_INET, "127.0.0.1", &service.sin_addr);
        service.sin_port = htons(port);

        // 如果 bind 失败返回 SOCKET_ERROR，说明端口名花有主被占用了
        if (bind(ListenSocket, (SOCKADDR*)&service, sizeof(service)) == SOCKET_ERROR) {
            closesocket(ListenSocket);
            WSACleanup();
            return false; 
        }

        // 测试绑定成功，这说明端口自由，最后清理资源
        closesocket(ListenSocket);
        WSACleanup();
        return true;
    }
}
