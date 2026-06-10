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
            Check("Add(negative)", service.Add(-40, -2), -42);
            Check("Sum", service.Sum(2000000000L, 1000000000L), 3000000000L);
            Check("Sum(negative)", service.Sum(-2000000000L, -1000000000L), -3000000000L);
            Check("Multiply", service.Multiply(2.5, 4.0), 10.0);
            Check("Multiply(negative)", service.Multiply(-2.5, 4.0), -10.0);
            Check("IsPositive(-5)", service.IsPositive(-5), false);
            Check("IsPositive(7)", service.IsPositive(7), true);

            // String edge cases: empty, multi-byte UTF-8, and a string long
            // enough to need a multi-byte 7-bit-encoded length prefix.
            Check("Echo(empty)", service.Echo(""), "");
            string unicode = "Příliš žluťoučký kůň \U0001F40E";
            Check("Echo(unicode)", service.Echo(unicode), unicode);
            string longStr = new string('x', 20000);
            Check("Echo(20000 chars)", service.Echo(longStr) == longStr, true);

            Check("EchoDecimal", service.EchoDecimal(123.45m), 123.45m);
            Check("EchoDecimal(negative)", service.EchoDecimal(-0.001m), -0.001m);
            DateTime utc = new DateTime(637500000000000000L, DateTimeKind.Utc);
            Check("EchoDateTime ticks", service.EchoDateTime(utc).Ticks, utc.Ticks);
            Check("EchoDateTime kind", service.EchoDateTime(utc).Kind, utc.Kind);
            TimeSpan span = TimeSpan.FromTicks(123456789L);
            Check("EchoTimeSpan", service.EchoTimeSpan(span), span);
            Check("MultiplyFloat", service.MultiplyFloat(2.5f, 4.0f), 10.0f);
            Check("EchoChar", service.EchoChar('Ω'), 'Ω');
            Check("IncrementByte", service.IncrementByte((byte)41), (byte)42);
            Check("NegateSByte", service.NegateSByte((sbyte)-42), (sbyte)42);
            Check("NegateShort", service.NegateShort((short)12345), (short)-12345);
            Check("EchoUInt16", service.EchoUInt16(ushort.MaxValue), ushort.MaxValue);
            Check("EchoUInt32", service.EchoUInt32(uint.MaxValue), uint.MaxValue);
            Check("EchoUInt64", service.EchoUInt64(ulong.MaxValue), ulong.MaxValue);
            service.Ping();
            Console.WriteLine("Ping -> ok (PASS)");

            if (failures > 0)
            {
                Console.WriteLine(failures + " call(s) failed.");
                Environment.Exit(1);
            }
            Console.WriteLine("All .NET client calls passed.");
        }
    }
}
