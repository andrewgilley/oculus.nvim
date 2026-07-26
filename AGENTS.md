For every logical block you create or modify, surround the block with temporary
comments containing the exact tokens AGENT_CHANGE_BEGIN and AGENT_CHANGE_END. U
se the file’s native comment syntax. Each begin marker must include the current
change-session identifier, a sequential block number, and a concise description.
Each end marker must include the same session identifier and block number. Mark
each logical changed block once; do not mark individual changed lines. Do not pl
ace comments in file formats that prohibit comments. For those files, add the f
ilename, approximate line number, session identifier, block number, and descrip
tion to a temporary .agent-changes manifest at the project root.
