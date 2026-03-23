cmake_minimum_required(VERSION 3.10)
project(LumiLauncher VERSION 1.0)

# 设置 C++ 标准为 C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED True)

# 添加源文件。前期方便调试我们先用普通的 Console 程序
# 等后续完善了，可以改成纯后台运行的 WIN32 程序 (add_executable(LumiLauncher WIN32 src/main.cpp))
add_executable(LumiLauncher src/main.cpp src/env_checker.cpp)

# 强制 MSVC 使用 UTF-8 编码读取源码，彻底解决中文报错 (C4819, C2001)
# 同时开启 WIN32_LEAN_AND_MEAN 解决 windows.h 与 winsock2.h 经典冲突
if(MSVC)
    target_compile_options(LumiLauncher PRIVATE /utf-8)
    target_compile_definitions(LumiLauncher PRIVATE WIN32_LEAN_AND_MEAN)
endif()

# 如果后续要链接 Windows 系统原生 API（比如进程管理、系统托盘等）可以加在这里
target_link_libraries(LumiLauncher PRIVATE Kernel32 User32 ws2_32)
