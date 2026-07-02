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

        public int[] EchoIntArray(int[] values) => values;
        public double[] EchoDoubleArray(double[] values) => values;
        public int SumIntArray(int[] values)
        {
            int sum = 0;
            foreach (int v in values) sum += v;
            return sum;
        }
        public string[] EchoStringArray(string[] values) => values;
        public string JoinStrings(string[] values, string separator) => string.Join(separator, values);
        public int[] MakeRange(int start, int count)
        {
            int[] result = new int[count];
            for (int i = 0; i < count; i++) result[i] = start + i;
            return result;
        }

        public double EchoDouble(double value) => value;
        public byte[] EchoByteArray(byte[] data) => data;
        public string[] MakeNulls(int count) => new string[count];

        public Person EchoPerson(Person person) => person;
        public string DescribePerson(Person person) => person.Name + ":" + person.Age;
        public Person MakePerson(string name, int age) => new Person { Name = name, Age = age, Score = age * 0.5 };
        public Person[] EchoPersonArray(Person[] people) => people;
        public Person[] MakeTwins(string name, int age)
        {
            Person p = new Person { Name = name, Age = age, Score = age * 2.0 };
            return new Person[] { p, p };
        }
        public Employee EchoEmployee(Employee employee) => employee;
        public string DescribeEmployee(Employee employee) => employee.Name + "@" + employee.Home.City;
        public bool HomesShared(Employee[] employees) =>
            ReferenceEquals(employees[0].Home, employees[1].Home);
        public Employee[] MakeCoworkers(string name1, string name2, string city)
        {
            Address home = new Address { Street = "Shared 1", City = city };
            return new Employee[]
            {
                new Employee { Name = name1, Home = home },
                new Employee { Name = name2, Home = home }
            };
        }
        public void ThrowError(string message) => throw new Exception(message);
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
