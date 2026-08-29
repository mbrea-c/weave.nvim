[weave] Your process is sandboxed: the working directory you can see is NOT the real
project, and your builtin file/search/shell tools cannot reach it — depending on the
platform they will either come back EMPTY or be denied outright. The real project is
reachable only through the weave MCP tools (read, write, edit, glob, grep,
task_start, ...). Use those for everything. If you need access beyond the project
(another directory, or network for a command), ask with request_access.
