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
        public object EchoObject(object value) => value;
        public object[] EchoObjectArray(object[] values) => values;
        private string lastOneWayMessage = "";
        // Mono's server-side sink checks OneWay on the resolved method (this
        // implementation), not the interface: without it a reply frame is
        // sent, desyncing clients that fired and forgot
        [System.Runtime.Remoting.Messaging.OneWay]
        public void FireAndForget(string message) { lastOneWayMessage = message; }
        public string GetLastOneWayMessage() { return lastOneWayMessage; }
        public void ThrowError(string message) => throw new Exception(message);

        public Node MakeRing(int size)
        {
            Node head = new Node { Label = "n0" };
            Node tail = head;
            for (int i = 1; i < size; i++)
            {
                tail.Next = new Node { Label = "n" + i };
                tail = tail.Next;
            }
            tail.Next = head;
            return head;
        }
        public Node MakeNarcissist()
        {
            Node n = new Node { Label = "me" };
            n.Next = n;
            return n;
        }
        public object[] MakeKlein()
        {
            object[] arr = new object[2];
            arr[0] = arr;
            arr[1] = "hi";
            return arr;
        }
        public bool IsRing(Node head, int expectedSize)
        {
            if (head == null || expectedSize < 1) return false;
            Node current = head;
            for (int i = 1; i < expectedSize; i++)
            {
                current = current.Next;
                if (current == null || ReferenceEquals(current, head)) return false;
            }
            return ReferenceEquals(current.Next, head);
        }
        public bool IsKlein(object[] arr) =>
            arr != null && arr.Length > 0 && ReferenceEquals(arr[0], arr);

        public char[] EchoCharArray(char[] values) => values;

        public int[,] EchoMatrix(int[,] m) => m;
        public int SumMatrix(int[,] m)
        {
            int sum = 0;
            foreach (int v in m) sum += v;
            return sum;
        }
        public int[,] MakeMatrix(int rows, int cols)
        {
            int[,] m = new int[rows, cols];
            for (int i = 0; i < rows; i++)
                for (int j = 0; j < cols; j++)
                    m[i, j] = i * 10 + j;
            return m;
        }
        public Array MakeVintageArray()
        {
            Array a = Array.CreateInstance(typeof(string), new[] { 3 }, new[] { 7 });
            a.SetValue("seven", 7);
            a.SetValue("eight", 8);
            a.SetValue("nine", 9);
            return a;
        }
        public string DescribeVintage(Array values)
        {
            string joined = "";
            for (int i = values.GetLowerBound(0); i <= values.GetUpperBound(0); i++)
            {
                if (i > values.GetLowerBound(0)) joined += ",";
                joined += (string)values.GetValue(i);
            }
            return values.GetLowerBound(0) + ":" + values.Length + ":" + joined;
        }

        public Node MakeDeepList(int depth)
        {
            Node head = null;
            for (int i = depth - 1; i >= 0; i--)
                head = new Node { Label = "d" + i, Next = head };
            return head;
        }
        public int DepthOf(Node head)
        {
            int depth = 0;
            for (Node current = head; current != null; current = current.Next)
                depth++;
            return depth;
        }
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
