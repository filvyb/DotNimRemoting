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

        static void CheckSeq<T>(string name, T[] actual, T[] expected)
        {
            bool ok = actual != null && actual.Length == expected.Length;
            if (ok)
            {
                for (int i = 0; i < expected.Length; i++)
                {
                    if (!Equals(actual[i], expected[i])) { ok = false; break; }
                }
            }
            string shown = actual == null ? "null" : "[" + string.Join(", ", Array.ConvertAll(actual, v => v == null ? "null" : v.ToString())) + "]";
            Console.WriteLine(name + " -> " + shown + (ok ? " (PASS)" : " (FAIL)"));
            if (!ok) failures++;
        }

        static void CheckPerson(string name, Person actual, string expName, int expAge, double expScore)
        {
            bool ok = actual != null && actual.Name == expName && actual.Age == expAge && actual.Score == expScore;
            string shown = actual == null ? "null" : actual.Name + "/" + actual.Age + "/" + actual.Score;
            Console.WriteLine(name + " -> " + shown + (ok ? " (PASS)" : " (FAIL, expected " + expName + "/" + expAge + "/" + expScore + ")"));
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

            // Special double bit patterns
            Check("EchoDouble(NaN)", double.IsNaN(service.EchoDouble(double.NaN)), true);
            Check("EchoDouble(+Inf)", service.EchoDouble(double.PositiveInfinity), double.PositiveInfinity);
            Check("EchoDouble(-Inf)", service.EchoDouble(double.NegativeInfinity), double.NegativeInfinity);

            // Arrays
            CheckSeq("EchoIntArray", service.EchoIntArray(new int[] { 1, 2, 3, -4 }), new int[] { 1, 2, 3, -4 });
            CheckSeq("EchoIntArray(empty)", service.EchoIntArray(new int[0]), new int[0]);
            CheckSeq("EchoDoubleArray", service.EchoDoubleArray(new double[] { 1.5, -2.25, 0.0 }), new double[] { 1.5, -2.25, 0.0 });
            Check("SumIntArray", service.SumIntArray(new int[] { 1, 2, 3, 4, 5 }), 15);
            CheckSeq("EchoStringArray", service.EchoStringArray(new string[] { "alpha", null, "gamma" }), new string[] { "alpha", null, "gamma" });
            Check("JoinStrings", service.JoinStrings(new string[] { "a", "b", "c" }, "-"), "a-b-c");
            CheckSeq("MakeRange", service.MakeRange(5, 4), new int[] { 5, 6, 7, 8 });
            CheckSeq("EchoByteArray", service.EchoByteArray(new byte[] { 0, 1, 127, 128, 255 }), new byte[] { 0, 1, 127, 128, 255 });

            // Consecutive nulls travel as ObjectNullMultiple256 records
            string[] nullRun = new string[] { "x", null, null, null, "y", null, null };
            CheckSeq("EchoStringArray(null run)", service.EchoStringArray(nullRun), nullRun);

            // 300 nulls force the 32-bit ObjectNullMultiple record
            string[] nulls = service.MakeNulls(300);
            bool nullsOk = nulls != null && nulls.Length == 300;
            if (nullsOk)
            {
                foreach (string s in nulls)
                {
                    if (s != null) { nullsOk = false; break; }
                }
            }
            Console.WriteLine("MakeNulls(300) -> " + (nulls == null ? "null" : nulls.Length + " elements") + (nullsOk ? " (PASS)" : " (FAIL)"));
            if (!nullsOk) failures++;

            // Classes
            Person echoed = service.EchoPerson(new Person { Name = "Ada", Age = 36, Score = 99.5 });
            CheckPerson("EchoPerson", echoed, "Ada", 36, 99.5);
            Check("DescribePerson", service.DescribePerson(new Person { Name = "Bob", Age = 25, Score = 1.0 }), "Bob:25");
            CheckPerson("MakePerson", service.MakePerson("Carol", 30), "Carol", 30, 15.0);
            Person[] people = service.EchoPersonArray(new Person[] {
                new Person { Name = "Dan", Age = 1, Score = 0.5 },
                new Person { Name = "Eve", Age = 2, Score = 1.5 }
            });
            bool peopleOk = people != null && people.Length == 2;
            if (peopleOk) CheckPerson("EchoPersonArray[0]", people[0], "Dan", 1, 0.5);
            if (peopleOk) CheckPerson("EchoPersonArray[1]", people[1], "Eve", 2, 1.5);
            if (!peopleOk)
            {
                Console.WriteLine("EchoPersonArray -> wrong length (FAIL)");
                failures++;
            }

            // Same instance twice: serialized as one record plus a MemberReference
            Person shared = new Person { Name = "Finn", Age = 3, Score = 2.5 };
            Person[] sharedEcho = service.EchoPersonArray(new Person[] { shared, shared });
            bool sharedOk = sharedEcho != null && sharedEcho.Length == 2;
            if (sharedOk) CheckPerson("EchoPersonArray(shared)[0]", sharedEcho[0], "Finn", 3, 2.5);
            if (sharedOk) CheckPerson("EchoPersonArray(shared)[1]", sharedEcho[1], "Finn", 3, 2.5);
            if (!sharedOk)
            {
                Console.WriteLine("EchoPersonArray(shared) -> wrong length (FAIL)");
                failures++;
            }

            // The Nim server returns the same value twice, so the wire format
            // must dedupe and .NET must materialize a single shared object
            Person[] twins = service.MakeTwins("Gemini", 9);
            bool twinsOk = twins != null && twins.Length == 2;
            if (twinsOk) CheckPerson("MakeTwins[0]", twins[0], "Gemini", 9, 18.0);
            if (twinsOk) Check("MakeTwins identity", ReferenceEquals(twins[0], twins[1]), true);
            if (!twinsOk)
            {
                Console.WriteLine("MakeTwins -> wrong length (FAIL)");
                failures++;
            }

            // Null object round-trip
            Check("EchoPerson(null)", service.EchoPerson(null), null);

            // Nested classes
            Employee emp = service.EchoEmployee(new Employee
            {
                Name = "Frank",
                Home = new Address { Street = "Main 5", City = "Brno" }
            });
            bool empOk = emp != null && emp.Name == "Frank" && emp.Home != null
                && emp.Home.Street == "Main 5" && emp.Home.City == "Brno";
            string empShown = emp == null ? "null"
                : emp.Name + "/" + (emp.Home == null ? "null" : emp.Home.Street + "/" + emp.Home.City);
            Console.WriteLine("EchoEmployee -> " + empShown + (empOk ? " (PASS)" : " (FAIL)"));
            if (!empOk) failures++;
            Check("DescribeEmployee", service.DescribeEmployee(new Employee
            {
                Name = "Grace",
                Home = new Address { Street = "Side 9", City = "Praha" }
            }), "Grace@Praha");

            // Diamond graph: array -> two Employees -> one shared Address.
            // The Nim server must resolve the member-level MemberReference to
            // a single instance...
            Address sharedHome = new Address { Street = "Diamond 7", City = "Ostrava" };
            Check("HomesShared(diamond)", service.HomesShared(new Employee[]
            {
                new Employee { Name = "Hana", Home = sharedHome },
                new Employee { Name = "Ivan", Home = sharedHome }
            }), true);
            // ...but equal-valued distinct Addresses must stay two objects
            Check("HomesShared(distinct)", service.HomesShared(new Employee[]
            {
                new Employee { Name = "Hana", Home = new Address { Street = "Diamond 7", City = "Ostrava" } },
                new Employee { Name = "Ivan", Home = new Address { Street = "Diamond 7", City = "Ostrava" } }
            }), false);

            // The Nim server builds the diamond; .NET must materialize one
            // shared Address instance behind both Home members
            Employee[] coworkers = service.MakeCoworkers("Jana", "Karel", "Plzen");
            bool coworkersOk = coworkers != null && coworkers.Length == 2
                && coworkers[0].Name == "Jana" && coworkers[1].Name == "Karel"
                && coworkers[0].Home != null && coworkers[0].Home.Street == "Shared 1"
                && coworkers[0].Home.City == "Plzen";
            Console.WriteLine("MakeCoworkers -> " + (coworkersOk ? "Jana&Karel@Plzen (PASS)" : "wrong content (FAIL)"));
            if (!coworkersOk) failures++;
            if (coworkersOk) Check("MakeCoworkers identity", ReferenceEquals(coworkers[0].Home, coworkers[1].Home), true);

            // The Nim handler raises; the reply must carry a serialized
            // System.Exception that deserializes and rethrows here
            try
            {
                service.ThrowError("boom from .NET");
                Console.WriteLine("ThrowError -> no exception (FAIL)");
                failures++;
            }
            catch (Exception e)
            {
                bool exOk = e.Message.Contains("boom from .NET");
                Console.WriteLine("ThrowError -> " + e.GetType().Name + ": " + e.Message + (exOk ? " (PASS)" : " (FAIL)"));
                if (!exOk) failures++;
            }
            // An exception reply is a normal reply: the channel must stay usable
            Check("Echo(after exception)", service.Echo("still alive"), "still alive");

            if (failures > 0)
            {
                Console.WriteLine(failures + " call(s) failed.");
                Environment.Exit(1);
            }
            Console.WriteLine("All .NET client calls passed.");
        }
    }
}
