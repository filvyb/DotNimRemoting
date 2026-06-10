namespace DotNimTester.Lib
{
    [System.Serializable]
    public class Person
    {
        // Plain public fields so MS-NRBF member names stay simple
        // (auto-properties would serialize as <Name>k__BackingField)
        public string Name;
        public int Age;
        public double Score;
    }

    public interface IEchoService
    {
        // string round-trip
        string Echo(string message);
        // two string args -> string
        string Concat(string a, string b);
        // two int args -> int
        int Add(int a, int b);
        // two long args -> long (int64)
        long Sum(long a, long b);
        // two double args -> double
        double Multiply(double a, double b);
        // int arg -> bool
        bool IsPositive(int value);
        // decimal round-trip (serialized as length-prefixed string)
        decimal EchoDecimal(decimal value);
        // DateTime round-trip (ticks + kind bit-packed into 8 bytes)
        System.DateTime EchoDateTime(System.DateTime value);
        // TimeSpan round-trip (int64 ticks)
        System.TimeSpan EchoTimeSpan(System.TimeSpan value);
        // two float args -> float (single precision)
        float MultiplyFloat(float a, float b);
        // char round-trip (UTF-8 on the wire)
        char EchoChar(char value);
        // byte arithmetic
        byte IncrementByte(byte value);
        // sbyte arithmetic
        sbyte NegateSByte(sbyte value);
        // short arithmetic
        short NegateShort(short value);
        // unsigned round-trips
        ushort EchoUInt16(ushort value);
        uint EchoUInt32(uint value);
        ulong EchoUInt64(ulong value);
        // void return
        void Ping();

        // primitive array round-trips (ArraySinglePrimitive on the wire)
        int[] EchoIntArray(int[] values);
        double[] EchoDoubleArray(double[] values);
        // array arg -> primitive return
        int SumIntArray(int[] values);
        // string array round-trip, null elements included (ArraySingleString)
        string[] EchoStringArray(string[] values);
        // mixed args: array + string -> string
        string JoinStrings(string[] values, string separator);
        // primitive args -> array return
        int[] MakeRange(int start, int count);

        // class round-trip (ClassWithMembersAndTypes)
        Person EchoPerson(Person person);
        // class arg -> string return
        string DescribePerson(Person person);
        // primitive args -> class return
        Person MakePerson(string name, int age);
        // array of classes round-trip (BinaryArray of class type)
        Person[] EchoPersonArray(Person[] people);
    }
}
