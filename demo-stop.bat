@echo off
echo Stopping demo services on ports 8080, 8000, 5173...

powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort 8080,8000,5173 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }"

echo Done. Any leftover "Brain/Console Backend/Frontend" windows can be closed manually.
pause
