using System;
using System.Runtime.Remoting;
using System.Runtime.Remoting.Channels;
using System.Runtime.Remoting.Channels.Tcp;
using DotNimTester.Lib;

namespace Server
{
    public class EchoService : MarshalByRefObject, IEchoService
    {
        public string Echo(string message) => message;
        public string Concat(string a, string b) => a + b;
        public int Add(int a, int b) => a + b;
        public long Sum(long a, long b) => a + b;
        public double Multiply(double a, double b) => a * b;
        public bool IsPositive(int value) => value > 0;
        public decimal EchoDecimal(decimal value) => value;
        public DateTime EchoDateTime(DateTime value) => value;
        public TimeSpan EchoTimeSpan(TimeSpan value) => value;
        public float MultiplyFloat(float a, float b) => a * b;
        public char EchoChar(char value) => value;
        public byte IncrementByte(byte value) => (byte)(value + 1);
        public sbyte NegateSByte(sbyte value) => (sbyte)(-value);
        public short NegateShort(short value) => (short)(-value);
        public ushort EchoUInt16(ushort value) => value;
        public uint EchoUInt32(uint value) => value;
        public ulong EchoUInt64(ulong value) => value;
        public void Ping() { }
    }

    class Program
    {
        static void Main()
        {
            TcpChannel channel = new TcpChannel(8080);
            ChannelServices.RegisterChannel(channel, false);
            RemotingConfiguration.RegisterWellKnownServiceType(
                typeof(EchoService), "EchoService", WellKnownObjectMode.Singleton);
            Console.WriteLine("Server running on tcp://127.0.0.1:8080/EchoService");
            Console.ReadLine();
        }
    }
}
