import os
import shutil
import time
import asyncio
import re
import fnmatch
import logging
logger = logging.getLogger("lumi")

# 该模块提供“本地文件工具”能力，供 AI 在受控范围内读写工程文件。

def read_file(path: str, start_line: int = 1, end_line: int = None) -> str:
    """读取本地文件内容，支持指定行范围。"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        if not os.path.isfile(path):
            return f"Error: '{path}' is not a file."
        
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
            
        total_lines = len(lines)
        # 1-indexed conversion
        start = max(0, start_line - 1)
        end = end_line if end_line is not None else total_lines
        end = min(total_lines, end)
        
        if start >= total_lines:
            return f"Error: start_line {start_line} exceeds total lines {total_lines}."
            
        selected_lines = lines[start:end]
        output = []
        for i, line in enumerate(selected_lines):
            # 仅移除行尾换行符，保留所有空格，确保 AI 能看到真实的缩进和尾随空格
            line_content = line.replace("\n", "").replace("\r", "")
            output.append(f"L{start + i + 1}: {line_content}")
            
        summary = f"\n--- Lines {start+1} to {end} of {total_lines} ---"
        hint = "\n[AI HINT] Code read successful. You can now use `insert_content` or `replace_content` to apply changes. Refer to 'Lx' for line numbers."
        return "\n".join(output) + summary + hint
    except Exception as e:
        return f"Error reading file: {e}"

def revert_file(path: str, workspace_dir: str = None) -> tuple[bool, str]:
    """回退单个文件的修改。基于 Git 进行还原（已跟踪文件使用 git checkout，新创建的未跟踪文件自动删除）。"""
    import subprocess
    try:
        abs_path = os.path.abspath(path)
        base_dir = os.path.dirname(abs_path)
        ws = workspace_dir or base_dir

        # 1. 优先尝试 Git 还原
        git_dir = os.path.join(ws, ".git") if os.path.isdir(ws) else None
        if not git_dir and os.path.exists(os.path.join(base_dir, ".git")):
            git_dir = os.path.join(base_dir, ".git")
            ws = base_dir

        if git_dir and os.path.exists(git_dir):
            # 检查文件是否为未跟踪的新文件
            status_proc = subprocess.run(
                ["git", "status", "--porcelain", abs_path],
                cwd=ws,
                capture_output=True,
                text=True,
                timeout=5,
            )
            out = status_proc.stdout.strip()
            if out.startswith("??"):
                # 新建未跟踪文件：直接删除
                if os.path.exists(abs_path):
                    os.remove(abs_path)
                    logger.info(f"[Lumi-Hub] 回退代码：已删除新建文件 {abs_path}")
                    return True, f"已删除新建的文件 {os.path.basename(abs_path)}"
            else:
                # 已跟踪的文件变更：使用 git checkout 还原
                restore_proc = subprocess.run(
                    ["git", "checkout", "--", abs_path],
                    cwd=ws,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if restore_proc.returncode == 0:
                    logger.info(f"[Lumi-Hub] 回退代码：Git 已还原 {abs_path}")
                    return True, f"已通过 Git 还原 {os.path.basename(abs_path)}"

        return False, f"未检测到 {os.path.basename(abs_path)} 的 Git 变更（或该工作区未纳入 Git）"
    except Exception as e:
        logger.error(f"[Lumi-Hub] 回退文件失败! 路径: {path}, 错误: {e}")
        return False, f"还原 {path} 失败: {e}"

def list_dir(path: str) -> str:
    """列出目录下文件"""
    try:
        if not os.path.exists(path):
            return f"Error: Directory '{path}' does not exist."
        if not os.path.isdir(path):
            return f"Error: '{path}' is not a directory."
        res = []
        for x in os.listdir(path):
            try:
                full_path = os.path.join(path, x)
                is_dir = "DIR " if os.path.isdir(full_path) else "FILE"
                res.append(f"[{is_dir}] {x}")
            except Exception:
                res.append(f"[UNKNOWN] {x}")
        return "\n".join(res)
    except Exception as e:
        return f"Error listing dir: {e}"

        
def write_file(path: str, content: str) -> str:
    """写入文件内容"""
    try:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return f"Successfully wrote to {path}"
    except Exception as e:
        return f"Error writing file: {e}"

def delete_file(path: str) -> str:
    """删除文件"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        os.remove(path)
        return f"Successfully deleted {path}"
    except Exception as e:
        return f"Error deleting file: {e}"

def replace_content(path: str, old_content: str, new_content: str) -> str:
    """部分替换文件内容 (针对单行或简单代码块)"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        
        with open(path, 'r', encoding='utf-8') as f:
            text = f.read()
        
        if old_content not in text:
            return f"Error: Could not find the specified old_content in {path}. Please call read_file to inspect the exact line content and indentation before retrying."
        
        count = text.count(old_content)
        if count > 1:
            return f"Error: Found {count} occurrences of old_content in {path}. The old_content must be unique. Please include more surrounding lines of context to make it unambiguous."
        
        updated_text = text.replace(old_content, new_content)
        
        with open(path, 'w', encoding='utf-8') as f:
            f.write(updated_text)
        
        return f"Successfully updated {path}."
    except Exception as e:
        return f"Error replacing content: {e}"

def insert_content(path: str, line_number: int, content: str) -> str:
    """在指定行号位置插入内容 (1-indexed)"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        
        with open(path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        total_lines = len(lines)
        idx = max(0, line_number - 1)
        if idx >= total_lines:
            lines.append(content + "\n")
        else:
            lines.insert(idx, content + "\n")
            
        with open(path, 'w', encoding='utf-8') as f:
            f.writelines(lines)
            
        return f"Successfully inserted content at line {line_number} in {path}."
    except Exception as e:
        return f"Error inserting content: {e}"

def search_replace(path: str, search_block: str, replace_block: str) -> str:
    """IDE 风格的搜索替换工具。鲁棒性增强：忽略行尾空格差异。"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        
        with open(path, 'r', encoding='utf-8') as f:
            full_content = f.read()
        
        lines = full_content.splitlines()
        search_lines = search_block.splitlines()
        
        match_start = -1
        match_count = 0
        
        for i in range(len(lines) - len(search_lines) + 1):
            is_match = True
            for j in range(len(search_lines)):
                # 比较时忽略行尾空格
                if lines[i+j].rstrip() != search_lines[j].rstrip():
                    is_match = False
                    break
            if is_match:
                match_start = i
                match_count += 1
        
        if match_count == 0:
            return f"Error: Search block not found in {path}. Please ensure indentation matches exactly."
        if match_count > 1:
            return f"Error: Search block found {match_count} times. Please provide a more unique block."
        
        new_lines = lines[:match_start] + replace_block.splitlines() + lines[match_start + len(search_lines):]
        
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write("\n".join(new_lines) + "\n")
            
        return f"Successfully applied changes to {path}."
    except Exception as e:
        return f"Error in search_replace: {e}"

def get_file_size(path: str) -> str:
    """获取文件的字节数大小"""
    try:
        if not os.path.exists(path):
            return f"Error: File '{path}' does not exist."
        if not os.path.isfile(path):
            return f"Error: '{path}' is not a file."
        
        size = os.path.getsize(path)
        return f"File '{os.path.basename(path)}' size: {size} bytes ({size / 1024:.2f} KB, {size / 1024 / 1024:.2f} MB)"
    except Exception as e:
        return f"Error getting file size: {e}"


async def run_command(command: str, cwd: str = None, timeout: int = 60) -> str:
    """在指定工作目录下执行 Shell 命令，捕获 stdout、stderr 及退出状态码。"""
    try:
        working_dir = cwd if (cwd and os.path.exists(cwd)) else os.getcwd()

        # 安全防御：禁止可能导致严重破坏或系统挂起的极端危险命令
        forbidden = ["rm -rf /", "mkfs", ":(){ :|:& };:"]
        for f in forbidden:
            if f in command:
                return f"Error: Command '{command}' contains forbidden destructive pattern."

        logger.info(f"[Lumi-Hub run_command] Executing in {working_dir}: {command}")

        process = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=working_dir,
        )

        try:
            stdout_data, stderr_data = await asyncio.wait_for(
                process.communicate(), timeout=timeout
            )
        except asyncio.TimeoutError:
            try:
                process.kill()
            except Exception:
                pass
            return f"Error: Command timed out after {timeout} seconds."

        stdout_str = stdout_data.decode("utf-8", errors="replace").strip()
        stderr_str = stderr_data.decode("utf-8", errors="replace").strip()
        exit_code = process.returncode

        output_parts = [f"[Exit Code] {exit_code}"]
        if stdout_str:
            if len(stdout_str) > 8000:
                truncated = stdout_str[:4000] + f"\n... [输出过长，中间省略 {len(stdout_str)-8000} 字符] ...\n" + stdout_str[-4000:]
                output_parts.append(f"[Stdout]\n{truncated}")
            else:
                output_parts.append(f"[Stdout]\n{stdout_str}")

        if stderr_str:
            if len(stderr_str) > 4000:
                truncated = stderr_str[:2000] + f"\n... [错误输出过长，中间省略 {len(stderr_str)-4000} 字符] ...\n" + stderr_str[-2000:]
                output_parts.append(f"[Stderr]\n{truncated}")
            else:
                output_parts.append(f"[Stderr]\n{stderr_str}")

        if not stdout_str and not stderr_str:
            output_parts.append("[Output] (No output)")

        return "\n".join(output_parts)
    except Exception as e:
        return f"Error executing command: {e}"


# ===== 工程级代码与工作区检索工具 (Workspace Awareness & Code RAG) =====

IGNORED_DIRS = {
    ".git", ".idea", ".vscode", "build", ".dart_tool", "node_modules",
    "__pycache__", ".pytest_cache", ".venv", "venv", "env", ".Lumi_cache",
    "dist", "target", "bin", "obj", ".gradle"
}

BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".bmp", ".tiff",
    ".pdf", ".zip", ".tar", ".gz", ".7z", ".rar", ".mp3", ".mp4", ".wav",
    ".ogg", ".webm", ".pyc", ".pyd", ".dll", ".so", ".dylib", ".exe",
    ".bin", ".moc", ".moc3", ".model3.json"
}


def is_binary_file(path: str) -> bool:
    """快速判断是否为二进制文件或忽略文件"""
    _, ext = os.path.splitext(path.lower())
    return ext in BINARY_EXTENSIONS


def search_workspace(pattern: str, workspace_dir: str = "", max_results: int = 50) -> str:
    """在工作区目录下递归搜索匹配特定名称或通配符模式的文件与目录。"""
    root_dir = workspace_dir if (workspace_dir and os.path.exists(workspace_dir)) else os.getcwd()
    if not os.path.isdir(root_dir):
        return f"Error: '{root_dir}' is not a valid directory."

    pattern_lower = pattern.lower().strip()
    is_glob = any(ch in pattern_lower for ch in ("*", "?", "[", "]"))
    matches = []

    try:
        for root, dirs, files in os.walk(root_dir):
            # 过滤忽略目录，防止递归进入大型无关文件夹
            dirs[:] = [d for d in dirs if d not in IGNORED_DIRS and not d.startswith(".")]

            rel_root = os.path.relpath(root, root_dir)
            if rel_root == ".":
                rel_root = ""

            for name in files:
                rel_path = os.path.join(rel_root, name) if rel_root else name
                matched = False
                if is_glob:
                    if fnmatch.fnmatch(name.lower(), pattern_lower) or fnmatch.fnmatch(rel_path.lower(), pattern_lower):
                        matched = True
                else:
                    if pattern_lower in name.lower() or pattern_lower in rel_path.lower():
                        matched = True

                if matched:
                    full_p = os.path.join(root, name)
                    try:
                        sz = os.path.getsize(full_p)
                        size_str = f"{sz / 1024:.1f} KB" if sz > 1024 else f"{sz} B"
                    except Exception:
                        size_str = "unknown"
                    matches.append((rel_path, "FILE", size_str))
                    if len(matches) >= max_results:
                        break
            if len(matches) >= max_results:
                break

        if not matches:
            return f"No files found matching '{pattern}' in {root_dir}"

        lines = [f"Found {len(matches)} matches for '{pattern}' in {root_dir}:"]
        for p, kind, sz in matches:
            lines.append(f"  [{kind}] {p} ({sz})")
        if len(matches) >= max_results:
            lines.append(f"  ... (Reached max results limit: {max_results})")
        return "\n".join(lines)
    except Exception as e:
        return f"Error searching workspace: {e}"


def grep_code(query: str, path: str = "", is_regex: bool = False, case_sensitive: bool = False, max_results: int = 50, file_extension: str = "") -> str:
    """在指定路径或工作区内所有代码文件中快速检索文本或正则表达式匹配项。"""
    search_root = path if (path and os.path.exists(path)) else os.getcwd()
    if not os.path.exists(search_root):
        return f"Error: Path '{search_root}' does not exist."

    flags = 0 if case_sensitive else re.IGNORECASE
    regex = None
    if is_regex:
        try:
            regex = re.compile(query, flags)
        except re.error as e:
            return f"Error: Invalid regular expression '{query}': {e}"

    target_ext = file_extension.lower().strip()
    if target_ext and not target_ext.startswith("."):
        target_ext = "." + target_ext

    results = []
    total_matched_files = 0

    def search_file(file_path: str, rel_path: str):
        nonlocal results, total_matched_files
        if is_binary_file(file_path):
            return
        try:
            if os.path.getsize(file_path) > 2 * 1024 * 1024:  # 跳过大于 2MB 的巨大文件
                return
            with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                file_has_match = False
                for line_no, line in enumerate(f, start=1):
                    line_to_test = line if case_sensitive else line.lower()
                    query_to_test = query if case_sensitive else query.lower()

                    matched = False
                    if regex:
                        if regex.search(line):
                            matched = True
                    else:
                        if query_to_test in line_to_test:
                            matched = True

                    if matched:
                        if not file_has_match:
                            file_has_match = True
                            total_matched_files += 1
                        cleaned = line.rstrip("\r\n")
                        if len(cleaned) > 200:
                            cleaned = cleaned[:100] + " ... " + cleaned[-80:]
                        results.append(f"{rel_path}:{line_no}: {cleaned}")
                        if len(results) >= max_results:
                            return
        except Exception:
            pass

    if os.path.isfile(search_root):
        search_file(search_root, os.path.basename(search_root))
    else:
        for root, dirs, files in os.walk(search_root):
            dirs[:] = [d for d in dirs if d not in IGNORED_DIRS and not d.startswith(".")]
            rel_root = os.path.relpath(root, search_root)
            if rel_root == ".":
                rel_root = ""

            for name in files:
                if target_ext and not name.lower().endswith(target_ext):
                    continue
                full_path = os.path.join(root, name)
                rel_path = os.path.join(rel_root, name) if rel_root else name
                search_file(full_path, rel_path)
                if len(results) >= max_results:
                    break
            if len(results) >= max_results:
                break

    if not results:
        return f"No matches found for '{query}' in {search_root}"

    header = f"Found {len(results)} matches across {total_matched_files} files for '{query}':"
    if len(results) >= max_results:
        results.append(f"... (Reached max results limit: {max_results})")
    return header + "\n" + "\n".join(results)


def find_symbol(symbol: str, path: str = "", max_results: int = 30) -> str:
    """在代码库中快速定位符号（类、函数、方法、接口、结构体、枚举等）定义。"""
    search_root = path if (path and os.path.exists(path)) else os.getcwd()
    if not os.path.exists(search_root):
        return f"Error: Path '{search_root}' does not exist."

    escaped = re.escape(symbol.strip())
    pattern = re.compile(
        rf"(?:class|interface|struct|enum|mixin|trait|type|def|function|fn|func)\s+{escaped}\b"
        rf"|^\s*(?:[\w<>\[\],\s]+\s+)?{escaped}\s*\([^\)]*\)\s*(?:\{{|;|=>)"
        rf"|^\s*(?:const|let|var)\s+{escaped}\s*=\s*(?:function|\([^)]*\)\s*=>)",
        re.MULTILINE
    )

    code_extensions = {
        ".py", ".dart", ".ts", ".js", ".jsx", ".tsx",
        ".rs", ".go", ".c", ".cpp", ".cc", ".h", ".hpp",
        ".java", ".kt", ".cs", ".swift", ".lua", ".rb", ".php"
    }

    results = []
    def search_file(file_path: str, rel_path: str):
        nonlocal results
        try:
            with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                for line_no, line in enumerate(f, start=1):
                    if symbol not in line:
                        continue
                    if pattern.search(line):
                        cleaned = line.strip()
                        if len(cleaned) > 160:
                            cleaned = cleaned[:160] + "..."
                        results.append(f"{rel_path}:{line_no}: {cleaned}")
                        if len(results) >= max_results:
                            return
        except Exception:
            pass

    if os.path.isfile(search_root):
        search_file(search_root, os.path.basename(search_root))
    else:
        for root, dirs, files in os.walk(search_root):
            dirs[:] = [d for d in dirs if d not in IGNORED_DIRS and not d.startswith(".")]
            rel_root = os.path.relpath(root, search_root)
            if rel_root == ".":
                rel_root = ""

            for name in files:
                _, ext = os.path.splitext(name.lower())
                if ext not in code_extensions:
                    continue
                full_path = os.path.join(root, name)
                rel_path = os.path.join(rel_root, name) if rel_root else name
                search_file(full_path, rel_path)
                if len(results) >= max_results:
                    break
            if len(results) >= max_results:
                break

    if not results:
        return f"No symbol definition found for '{symbol}' in {search_root}. (Try using `grep_code` for broader text matches)"

    header = f"Found {len(results)} definitions for symbol '{symbol}':"
    if len(results) >= max_results:
        results.append(f"... (Reached max results limit: {max_results})")
    return header + "\n" + "\n".join(results)

