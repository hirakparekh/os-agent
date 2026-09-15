@echo off
cd /d "%~dp0"

echo Starting brain (8080), console backend (8000), frontend (5173)...

start "Brain :8080" cmd /k "uv run uvicorn brain.viz_server:app --port 8080"
start "Console Backend :8000" cmd /k "uv run uvicorn console.backend.main:app --port 8000"
start "Frontend :5173" cmd /k "cd console\frontend && npm run dev"

timeout /t 4 >nul
start http://localhost:5173

echo.
echo Demo is starting in 3 separate windows (one per service).
echo Close this window any time - the service windows keep running.
echo Login: teammate1@agent-os.local / 4xw64qwdrr
