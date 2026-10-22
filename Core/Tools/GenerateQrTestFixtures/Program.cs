using Aspose.BarCode.Generation;
using Aspose.Drawing.Imaging;

string repoTestFilesRoot = args.Length > 0
    ? args[0]
    : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "Fixtures", "QR", "NCP-7330"));

Directory.CreateDirectory(repoTestFilesRoot);

const string allowedUrl = "https://www.dbs.com/insightsdirect/macro";

WriteQrImage(Path.Combine(repoTestFilesRoot, "qr-allowed-url.png"), allowedUrl, ImageFormat.Png);
WriteQrImage(Path.Combine(repoTestFilesRoot, "qr-allowed-url.jpg"), allowedUrl, ImageFormat.Jpeg);

Console.WriteLine($"Wrote QR fixtures under: {repoTestFilesRoot}");

static void WriteQrImage(string path, string payload, ImageFormat format)
{
    using var generator = new BarcodeGenerator(EncodeTypes.QR, payload);
    generator.Parameters.Barcode.XDimension.Pixels = 4;
    using var image = generator.GenerateBarCodeImage();
    image.Save(path, format);
}
