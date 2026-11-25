param([string]$DllPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\WinDivert.dll'))

$source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public sealed class ApexUdpCapture : IDisposable
{
    private const string Dll = @"__DLL_PATH__";
    private const string DefaultFilter = "ip and udp and not loopback and not fragment";
    private const ulong SniffReadOnlyExistingDriver = 0x0001 | 0x0004 | 0x0010;
    private const int WinDivertNetworkLayer = 0;
    private const int StopReceiving = 1;
    private const int NoMorePackets = 232;
    private const int OutboundFlag = 1 << 17;

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
    private static extern IntPtr WinDivertOpen(string filter, int layer, short priority, ulong flags);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinDivertRecv(IntPtr handle, [Out] byte[] packet,
        uint packetLength, out uint received, [Out] byte[] address);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern bool WinDivertShutdown(IntPtr handle, int how);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern bool WinDivertClose(IntPtr handle);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern bool WinDivertHelperCompileFilter(string filter, int layer,
        [Out] byte[] compiled, uint capacity, out IntPtr error, out uint position);

    private volatile HashSet<int> apexPorts;
    private readonly Dictionary<string, int[]> flows = new Dictionary<string, int[]>();
    private readonly IntPtr handle;
    private readonly Task<Dictionary<string, int[]>> reader;
    private bool disposed;

    public static void ValidateFilter(string filter = DefaultFilter)
    {
        IntPtr error;
        uint position;
        if (!WinDivertHelperCompileFilter(filter, WinDivertNetworkLayer, new byte[8192], 8192,
                                           out error, out position))
            throw new ArgumentException(Marshal.PtrToStringAnsi(error) + " at " + position);
    }

    public ApexUdpCapture(int[] ports)
    {
        SetPorts(ports);
        // Observe original traffic before the normal Zapret handle processes it.
        handle = WinDivertOpen(DefaultFilter, WinDivertNetworkLayer, 1000, SniffReadOnlyExistingDriver);
        if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        reader = Task.Factory.StartNew<Dictionary<string, int[]>>(ReadPackets, TaskCreationOptions.LongRunning);
    }

    public void SetPorts(int[] ports)
    {
        apexPorts = new HashSet<int>(ports);
    }

    private Dictionary<string, int[]> ReadPackets()
    {

        var packet = new byte[65535];
        var address = new byte[80];
        uint received;
        while (WinDivertRecv(handle, packet, (uint)packet.Length, out received, address))
        {
            int udp = (packet[0] & 15) * 4;
            if (udp < 20 || received < udp + 8) continue;
            bool outbound = (BitConverter.ToInt32(address, 8) & OutboundFlag) != 0;
            int localPortOffset = outbound ? udp : udp + 2;
            int remotePortOffset = outbound ? udp + 2 : udp;
            int localPort = (packet[localPortOffset] << 8) | packet[localPortOffset + 1];
            if (!apexPorts.Contains(localPort)) continue;
            int remotePort = (packet[remotePortOffset] << 8) | packet[remotePortOffset + 1];
            int remoteIpOffset = outbound ? 16 : 12;
            var remoteIp = new IPAddress(new byte[] { packet[remoteIpOffset], packet[remoteIpOffset + 1],
                packet[remoteIpOffset + 2], packet[remoteIpOffset + 3] });
            string endpoint = remoteIp + ":" + remotePort;
            lock (flows)
            {
                int[] counts;
                if (!flows.TryGetValue(endpoint, out counts))
                {
                    if (flows.Count >= 512) continue;
                    flows.Add(endpoint, counts = new int[2]);
                }
                counts[outbound ? 0 : 1]++;
            }
        }
        int error = Marshal.GetLastWin32Error();
        if (error != NoMorePackets) throw new Win32Exception(error);
        return flows;
    }

    public Dictionary<string, int[]> Finish()
    {
        if (!WinDivertShutdown(handle, StopReceiving))
            throw new InvalidOperationException("Could not stop reading WinDivert packets.");
        return reader.GetAwaiter().GetResult();
    }

    public void Dispose()
    {
        if (disposed) return;
        WinDivertClose(handle);
        try { reader.GetAwaiter().GetResult(); } catch (Win32Exception) { }
        disposed = true;
    }
}
'@
if (-not ('ApexUdpCapture' -as [type])) { Add-Type -TypeDefinition $source.Replace('__DLL_PATH__', $DllPath.Replace('"','""')) }
