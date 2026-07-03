# Use a Windows Server Core image with .NET Framework 3.5
FROM mcr.microsoft.com/dotnet/framework/sdk:3.5-windowsservercore-ltsc2022

SHELL ["powershell", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# Install Nim
RUN Invoke-WebRequest -Uri 'https://nim-lang.org/download/nim-2.2.10_x64.zip' -OutFile 'nim.zip'; \
    Expand-Archive -Path 'nim.zip' -DestinationPath 'C:\'; \
    Rename-Item -Path 'C:\nim-2.2.10' -NewName 'nim'; \
    Remove-Item 'nim.zip'

# Install MinGW-w64
RUN Invoke-WebRequest -Uri 'https://nim-lang.org/download/mingw64.zip' -OutFile 'mingw.zip'; \
    Expand-Archive -Path 'mingw.zip' -DestinationPath 'C:\'; \
    Remove-Item 'mingw.zip'

# Install MinGit
RUN Invoke-WebRequest -Uri 'https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/MinGit-2.54.0-64-bit.zip' -OutFile 'mingit.zip'; \
    Expand-Archive -Path 'mingit.zip' -DestinationPath 'C:\mingit'; \
    Remove-Item 'mingit.zip'

RUN setx /M PATH ($Env:PATH + ';C:\nim\bin;C:\mingw64\bin;C:\mingit\cmd')

COPY . /app

WORKDIR /app/tests/dotnet/Server
RUN msbuild Server.csproj /p:Configuration=Release

WORKDIR /app/tests/dotnet/Client
RUN msbuild Client.csproj /p:Configuration=Release

WORKDIR /app
RUN nimble install --solver:legacy -d -y
RUN nim c --hints:off -d:nimCallDepthLimit=30000 tests/nim/client.nim
RUN nim c --hints:off -d:nimCallDepthLimit=30000 tests/nim/server.nim

WORKDIR /app
