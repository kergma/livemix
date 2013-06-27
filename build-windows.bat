@echo off
for /f %%i in ('cmd /c "git tag"') do (set tag=%%i)
set target=livemix-%tag%
echo tag %tag%
mkdir %target%
copy livemix.pl %target%\
copy README %target%\
copy README-windows.txt %target%\
cd %target%
pp -o livemix.exe livemix.pl

