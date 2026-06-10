using System;
using System.Runtime.Remoting.Channels;
using System.Runtime.Remoting.Channels.Tcp;
using DotNimTester.Lib;

namespace Client
{
    class Program
    {
        static int failures = 0;

        static void Check(string name, object actual, object expected)
        {
            bool ok = Equals(actual, expected);
            Console.WriteLine(name + " -> " + actual + (ok ? " (PASS)" : " (FAIL, expected " + expected + ")"));
            if (!ok) failures++;
        }

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

            Check("Echo", service.Echo("Hello from .NET"), "Hello from .NET");
            Check("Concat", service.Concat("foo", "bar"), "foobar");
            Check("Add", service.Add(40, 2), 42);
            Check("Sum", service.Sum(2000000000L, 1000000000L), 3000000000L);
            Check("Multiply", service.Multiply(2.5, 4.0), 10.0);
            Check("IsPositive(-5)", service.IsPositive(-5), false);
            Check("IsPositive(7)", service.IsPositive(7), true);

            if (failures > 0)
            {
                Console.WriteLine(failures + " call(s) failed.");
                Environment.Exit(1);
            }
            Console.WriteLine("All .NET client calls passed.");
        }
    }
}
