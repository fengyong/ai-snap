#!/bin/bash

REPO_DIR="/Users/fengyong/qoder/ai-snap"
LOG_FILE="$REPO_DIR/.qoder/auto_git_push.log"

cd "$REPO_DIR" || exit 1

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检查并提交代码..." >> "$LOG_FILE"
    
    # 检查是否有更改需要提交
    if [ -n "$(git status --porcelain)" ]; then
        git add -A
        git commit -m "Auto commit at $(date '+%Y-%m-%d %H:%M:%S')"
        
        # 推送到远程
        if git push origin master 2>> "$LOG_FILE"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 推送成功" >> "$LOG_FILE"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ 推送失败" >> "$LOG_FILE"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 没有需要提交的更改" >> "$LOG_FILE"
    fi
    
    # 等待10分钟
    sleep 600
done
