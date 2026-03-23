#include <iostream>
#include <windows.h>
#include "env_checker.h"

int main() {
    // 设置 Windows 控制台输出为 UTF-8 代码页，防止中文打印乱码
    SetConsoleOutputCP(CP_UTF8);
    
    std::cout << "=====================================================" << std::endl;
    std::cout << "🚀 Lumi-Hub C++ Native Launcher 启动中" << std::endl;
    std::cout << "=====================================================" << std::endl;
    std::cout << "[1/3] 执行核心环境自检..." << std::endl;
    
    // 1. 检查 Python 环境变量
    if (LumiHub::EnvChecker::isPythonAvailable()) {
        std::cout << "  ✅ Python 校验：已成功找到全局 Python 环境！" << std::endl;
    } else {
        std::cout << "  ❌ Python 校验：未找到 Python，请检查是否已正确安装并添加到 PATH！" << std::endl;
        std::cout << "环境异常，即将中止启动..." << std::endl;
        system("pause");
        return 1;
    }
    
    // 2. 检查后端所需的 Socket 端口
    int targetPort = 8765;
    if (LumiHub::EnvChecker::isPortAvailable(targetPort)) {
        std::cout << "  ✅ 端口校验：核心端口 [" << targetPort << "] 可用，未发生冲突！" << std::endl;
    } else {
        std::cout << "  ❌ 端口校验：核心端口 [" << targetPort << "] 已被占用！" << std::endl;
        std::cout << "（如果你刚刚运行过 Lumi-Hub，可能进程仍残留在后台，请前往任务管理器清理后重试）" << std::endl;
        std::cout << "环境异常，即将中止启动..." << std::endl;
        system("pause");
        return 1;
    }

    std::cout << "\n环境自检 100% 通过！准备拉起后面的守护进程..." << std::endl;
    
    // 暂停进程，方便你在 VS 调试时能看清屏幕输出
    system("pause");
    return 0;
}
