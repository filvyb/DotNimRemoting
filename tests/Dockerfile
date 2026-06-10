# Use a Windows Server Core image with .NET Framework 3.5
FROM mcr.microsoft.com/dotnet/framework/sdk:3.5-windowsservercore-ltsc2022

SHELL ["powershell", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# Install Nim
RUN Invoke-WebRequest -Uri 'https://nim-lang.org/download/nim-2.2.10_x64.zip' -OutFile 'nim.zip'; \
    Expand-Archive -Path 'nim.zip' -DestinationPath 'C:\'; \
    Rename-Item -Path 'C:\nim-2.2.10' -NewName 'nim'; \
    Remove-Item 'nim.zip'

RUN setx /M PATH ($Env:PATH + ';C:\nim\bin')

COPY . /app

WORKDIR /app/tests/dotnet/Server
RUN msbuild Server.csproj /p:Configuration=Release

WORKDIR /app/tests/dotnet/Client
RUN msbuild Client.csproj /p:Configuration=Release

WORKDIR /app
RUN nim c tests/nim/client.nim
RUN nim c tests/nim/server.nim

WORKDIR /app
