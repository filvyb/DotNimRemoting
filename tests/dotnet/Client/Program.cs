using System;
using System.Runtime.Remoting.Channels;
using System.Runtime.Remoting.Channels.Tcp;
using DotNimTester.Lib;

namespace Client
{
    class Program
    {
        static void Main(string[] args)
        {
            if (args.Length < 1)
            {
                Console.WriteLine("Usage: Client.exe <server-uri>");
                Environment.Exit(1);
            }
            TcpChannel channel = new TcpChannel();
            ChannelServices.RegisterChannel(channel, false);
            IEchoService service = (IEchoService)Activator.GetObject(
                typeof(IEchoService), args[0]);
            string response = service.Echo("Hello from .NET");
            Console.WriteLine("Response: " + response);
            if (response != "Hello from .NET") Environment.Exit(1);
        }
    }
}