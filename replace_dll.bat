cd "C:\Games\Steam\steamapps\common\Sven Co-op\svencoop\addons\metamod\dlls"

if exist AntiCheat_old.dll (
    del AntiCheat_old.dll
)
if exist AntiCheat.dll (
    rename AntiCheat.dll AntiCheat_old.dll 
)

exit /b 0