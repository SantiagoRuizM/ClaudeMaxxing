using System;
using System.Runtime.InteropServices;

// Signs an MSIX with a certificate from the Windows certificate store through mssign32.dll
// (the API signtool uses), so no Windows SDK is needed.
public static class MsixSigner
{
    [StructLayout(LayoutKind.Sequential)]
    struct SIGNER_FILE_INFO { public uint cbSize; [MarshalAs(UnmanagedType.LPWStr)] public string pwszFileName; public IntPtr hFile; }

    [StructLayout(LayoutKind.Sequential)]
    struct SIGNER_SUBJECT_INFO { public uint cbSize; public IntPtr pdwIndex; public uint dwSubjectChoice; public IntPtr pSignerFileInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct SIGNER_CERT_STORE_INFO { public uint cbSize; public IntPtr pSigningCert; public uint dwCertPolicy; public IntPtr hCertStore; }

    [StructLayout(LayoutKind.Sequential)]
    struct SIGNER_CERT { public uint cbSize; public uint dwCertChoice; public IntPtr pCertStoreInfo; public IntPtr hwnd; }

    [StructLayout(LayoutKind.Sequential)]
    struct SIGNER_SIGNATURE_INFO { public uint cbSize; public uint algidHash; public uint dwAttrChoice; public IntPtr pAttrAuthcode; public IntPtr psAuthenticated; public IntPtr psUnauthenticated; }

    [StructLayout(LayoutKind.Sequential)]
    struct SIGNER_SIGN_EX2_PARAMS
    {
        public uint dwFlags; public IntPtr pSubjectInfo; public IntPtr pSigningCert; public IntPtr pSignatureInfo;
        public IntPtr pProviderInfo; public uint dwTimestampFlags; public IntPtr pszAlgorithmOid; public IntPtr pwszTimestampURL;
        public IntPtr pCryptAttrs; public IntPtr pSipData; public IntPtr pSignerContext; public IntPtr pCryptoPolicy; public IntPtr pReserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct APPX_SIP_CLIENT_DATA { public IntPtr pSignerParams; public IntPtr pAppxSipState; }

    [DllImport("mssign32.dll", CharSet = CharSet.Unicode)]
    static extern int SignerSignEx2(uint dwFlags, IntPtr pSubjectInfo, IntPtr pSignerCert, IntPtr pSignatureInfo, IntPtr pProviderInfo,
        uint dwTimestampFlags, IntPtr pszTimestampAlgorithmOid, IntPtr pwszHttpTimeStamp, IntPtr psRequest, IntPtr pSipData,
        out IntPtr ppSignerContext, IntPtr pCryptoPolicy, IntPtr pReserved);

    [DllImport("mssign32.dll")]
    static extern int SignerFreeSignerContext(IntPtr pSignerContext);

    const uint SIGNER_SUBJECT_FILE = 1;
    const uint SIGNER_CERT_STORE = 2;
    const uint SIGNER_CERT_POLICY_CHAIN = 2;
    const uint CALG_SHA_256 = 0x800c;

    static IntPtr Alloc<T>(T value) { IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(T))); Marshal.StructureToPtr(value, p, false); return p; }

    // certContext: X509Certificate2.Handle of a certificate with its private key.
    public static void Sign(string path, IntPtr certContext)
    {
        var toFree = new System.Collections.Generic.List<IntPtr>();
        IntPtr context = IntPtr.Zero, sipData = IntPtr.Zero;
        try
        {
            IntPtr index = Marshal.AllocHGlobal(4); Marshal.WriteInt32(index, 0); toFree.Add(index);
            IntPtr fileInfo = Alloc(new SIGNER_FILE_INFO { cbSize = (uint)Marshal.SizeOf(typeof(SIGNER_FILE_INFO)), pwszFileName = path }); toFree.Add(fileInfo);
            IntPtr subject = Alloc(new SIGNER_SUBJECT_INFO { cbSize = (uint)Marshal.SizeOf(typeof(SIGNER_SUBJECT_INFO)), pdwIndex = index, dwSubjectChoice = SIGNER_SUBJECT_FILE, pSignerFileInfo = fileInfo }); toFree.Add(subject);
            IntPtr storeInfo = Alloc(new SIGNER_CERT_STORE_INFO { cbSize = (uint)Marshal.SizeOf(typeof(SIGNER_CERT_STORE_INFO)), pSigningCert = certContext, dwCertPolicy = SIGNER_CERT_POLICY_CHAIN }); toFree.Add(storeInfo);
            IntPtr cert = Alloc(new SIGNER_CERT { cbSize = (uint)Marshal.SizeOf(typeof(SIGNER_CERT)), dwCertChoice = SIGNER_CERT_STORE, pCertStoreInfo = storeInfo }); toFree.Add(cert);
            IntPtr sigInfo = Alloc(new SIGNER_SIGNATURE_INFO { cbSize = (uint)Marshal.SizeOf(typeof(SIGNER_SIGNATURE_INFO)), algidHash = CALG_SHA_256 }); toFree.Add(sigInfo);

            // MSIX signing goes through the Appx SIP, which needs the same parameters again in pSipData.
            IntPtr contextSlot = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(contextSlot, IntPtr.Zero); toFree.Add(contextSlot);
            IntPtr parameters = Alloc(new SIGNER_SIGN_EX2_PARAMS { pSubjectInfo = subject, pSigningCert = cert, pSignatureInfo = sigInfo, pSignerContext = contextSlot }); toFree.Add(parameters);
            sipData = Alloc(new APPX_SIP_CLIENT_DATA { pSignerParams = parameters });
            Marshal.StructureToPtr(new SIGNER_SIGN_EX2_PARAMS { pSubjectInfo = subject, pSigningCert = cert, pSignatureInfo = sigInfo, pSignerContext = contextSlot, pSipData = sipData }, parameters, true);

            int hr = SignerSignEx2(0, subject, cert, sigInfo, IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, sipData, out context, IntPtr.Zero, IntPtr.Zero);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            if (sipData != IntPtr.Zero)
            {
                var data = (APPX_SIP_CLIENT_DATA)Marshal.PtrToStructure(sipData, typeof(APPX_SIP_CLIENT_DATA));
                if (data.pAppxSipState != IntPtr.Zero) Marshal.Release(data.pAppxSipState);
                Marshal.FreeHGlobal(sipData);
            }
            if (context != IntPtr.Zero) SignerFreeSignerContext(context);
            foreach (IntPtr p in toFree) Marshal.FreeHGlobal(p);
        }
    }
}
