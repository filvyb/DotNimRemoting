namespace DotNimTester.Lib
{
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
    }
}
