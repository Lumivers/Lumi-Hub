#pragma once
#include <string>

namespace LumiHub {
    class EnvChecker {
    public:
        // 检查系统 PATH 环境变量中是否存在 Python
        // 返回 true 如果存在，false 如果不存在
        static bool isPythonAvailable();
        
        // 检查后端所需的端口是否被外部占用
        // 返回 true 如果端口空闲可用，false 如果被占用
        static bool isPortAvailable(int port);
    };
}
