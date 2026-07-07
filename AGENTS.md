# AGENTS.md

- 始终用中文回复 nanzhi。只有在用户明确要求其他语言，或代码、命令、日志、文件内容需要原样保留时，才使用非中文片段。
- 每次修改 popdict 的应用源码后，都必须更新本机 App:运行 `cd popdict-app && bash build.sh` 生成最新 `popdict.app` / `popdict.dmg`。
- 如果 `/Applications/popdict.app` 已存在，且用户没有明确要求只改源码，则必须停止正在运行的 popdict、替换 `/Applications/popdict.app`、再重新打开。
- 每次更新 App 后都要自己验收。至少确认编译/打包通过、安装版签名可验证、进程已重新启动；涉及 UI 的改动还要尽量做可执行的 UI/日志验收。
