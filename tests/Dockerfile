# Use a Windows Server Core image with .NET Framework 4.8
FROM mcr.microsoft.com/dotnet/framework/runtime:4.8-windowsservercore-ltsc2022

# Install Nim (adjust the version and URL as needed)
RUN powershell -Command "Invoke-WebRequest -Uri 'https://nim-lang.org/download/nim-2.2.2_x64.zip' -OutFile 'nim.zip'; Expand-Archive -Path 'nim.zip' -DestinationPath 'C:\nim'; Remove-Item 'nim.zip'"
ENV PATH="C:\nim\bin;${PATH}"

# Copy your application files into the container
COPY . /app

# Build .NET projects (adjust paths to match your project structure)
WORKDIR /app/tests/dotnet/Server
RUN msbuild Server.csproj /p:Configuration=Release

WORKDIR /app/tests/dotnet/Client
RUN msbuild Client.csproj /p:Configuration=Release

# Build Nim projects (adjust paths and filenames as needed)
WORKDIR /app
RUN nim c tests/nim/client.nim
RUN nim c tests/nim/server.nim

# Set the working directory for running tests
WORKDIR /app
