class Openssl < Formula
  desc "SSL/TLS cryptography library"
  homepage "https://openssl.org/"
  url "https://www.openssl.org/source/openssl-1.0.2k.tar.gz"
  mirror "https://dl.bintray.com/homebrew/mirror/openssl-1.0.2k.tar.gz"
  mirror "https://www.mirrorservice.org/sites/ftp.openssl.org/source/openssl-1.0.2k.tar.gz"
  sha256 "6b3977c61f2aedf0f96367dcfb5c6e578cf37e7b8d913b4ecb6643c3cb88d8c0"

  bottle do
    sha256 "109fe24d2ee82d89e1ee60587d91c953cdd3384db5374e8e83635c456fa15ed0" => :sierra
    sha256 "7b331c548a5a82f7a111c6218be3e255a2a1a6c19888c2b7ceaf02f2021c1628" => :el_capitan
    sha256 "a3083052e81d711dd6da2d5bda7418d321eba26570a63818e52f5f68247c63f2" => :yosemite
  end

  option :universal
  option "without-asm", "Do not use assembly optimized routines"
  option "without-test", "Skip build-time tests (not recommended)"

  depends_on :ld64

  depends_on "makedepend" => :build
  depends_on "curl-ca-bundle" if MacOS.version < :snow_leopard

  patch :p0 do
    url "https://trac.macports.org/export/144472/trunk/dports/devel/openssl/files/x86_64-asm-on-i386.patch"
    sha256 "98ffb308aa04c14db9c21769f1c5ff09d63eb85ce9afdf002598823c45edef6d"
  end

  patch :DATA if MacOS.version == :tiger
  
  def arch_args
    {
      :x86_64 => %w[darwin64-x86_64-cc enable-ec_nistp_64_gcc_128],
      :i386   => %w[darwin-i386-cc],
      :ppc    => %w[darwin-ppc-cc],
      :ppc64  => %w[darwin64-ppc-cc]
    }
  end

  def configure_args
    args = %W[ 
      --prefix=#{prefix}
      --openssldir=#{openssldir}
      no-ssl2
      zlib-dynamic
      shared
      enable-cms
    ]
    
    args << "no-asm" if build.without?("asm")

    args
  end

  def install
    # OpenSSL will prefer the PERL environment variable if set over $PATH
    # which can cause some odd edge cases & isn't intended. Unset for safety.
    ENV.delete("PERL")

    if build.universal?
      ENV.permit_arch_flags
      archs = Hardware::CPU.universal_archs
    elsif MacOS.prefer_64_bit?
      archs = [Hardware::CPU.arch_64_bit]
    else
      archs = [Hardware::CPU.arch_32_bit]
    end

    dirs = []

    archs.each do |arch|
      if build.universal?
        dir = "build-#{arch}"
        dirs << dir
        mkdir dir
        mkdir "#{dir}/engines"
        system "make", "clean"
      end

      ENV.deparallelize
      system "perl", "./Configure", *(configure_args + arch_args[arch])
      system "make", "depend"
      system "make"
      system "make", "test" if build.with?("test")

      if build.universal?
        cp "include/openssl/opensslconf.h", dir
        cp Dir["*.?.?.?.dylib"] + Dir["*.a"] + Dir["apps/openssl"], dir
        cp Dir["engines/**/*.dylib"], "#{dir}/engines"
      end
    end

    system "make", "install", "MANDIR=#{man}", "MANSUFFIX=ssl"

    if build.universal?
      %w[libcrypto libssl].each do |libname|
        system "lipo", "-create", "#{dirs.first}/#{libname}.1.0.0.dylib",
                                  "#{dirs.last}/#{libname}.1.0.0.dylib",
                       "-output", "#{lib}/#{libname}.1.0.0.dylib"
        system "lipo", "-create", "#{dirs.first}/#{libname}.a",
                                  "#{dirs.last}/#{libname}.a",
                       "-output", "#{lib}/#{libname}.a"
      end

      Dir.glob("#{dirs.first}/engines/*.dylib") do |engine|
        libname = File.basename(engine)
        system "lipo", "-create", "#{dirs.first}/engines/#{libname}",
                                  "#{dirs.last}/engines/#{libname}",
                       "-output", "#{lib}/engines/#{libname}"
      end

      system "lipo", "-create", "#{dirs.first}/openssl",
                                "#{dirs.last}/openssl",
                     "-output", "#{bin}/openssl"

    end
  end

  def openssldir
    etc/"openssl"
  end

  def post_install
    keychains = %w[
      /Library/Keychains/System.keychain    
      /System/Library/Keychains/SystemRootCertificates.keychain
    ]

    certs_list = `security find-certificate -a -p #{keychains.join(" ")}`
    certs = certs_list.scan(
      /-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m
    )

    valid_certs = certs.select do |cert|
      IO.popen("#{bin}/openssl x509 -inform pem -checkend 0 -noout", "w") do |openssl_io|
        openssl_io.write(cert)
        openssl_io.close_write
      end

      $?.success?
    end

    openssldir.mkpath
    (openssldir/"cert.pem").atomic_write(valid_certs.join("\n"))
  end if MacOS.version > :leopard

  def post_install
    rm_rf openssldir/"cert.pem"
    openssldir.install_symlink Formula["curl-ca-bundle"].opt_share/"ca-bundle.crt" => "cert.pem"
  end if MacOS.version <= :leopard

  def caveats; <<-EOS.undent
    A CA file has been bootstrapped using certificates from the SystemRoots
    keychain. To add additional certificates (e.g. the certificates added in
    the System keychain), place .pem files in
      #{openssldir}/certs

    and run
      #{opt_bin}/c_rehash
    EOS
  end

  test do
    # Make sure the necessary .cnf file exists, otherwise OpenSSL gets moody.
    cnf_path = HOMEBREW_PREFIX/"etc/openssl/openssl.cnf"
    assert cnf_path.exist?,
            "OpenSSL requires the .cnf file for some functionality"
            
    # Check OpenSSL itself functions as expected.
    (testpath/"testfile.txt").write("This is a test file")
    expected_checksum = "e2d0fe1585a63ec6009c8016ff8dda8b17719a637405a4e23c0ff81339148249"
    system "#{bin}/openssl", "dgst", "-sha256", "-out", "checksum.txt", "testfile.txt"
    open("checksum.txt") do |f|
      checksum = f.read(100).split("=").last.strip
      assert_equal checksum, expected_checksum
    end
  end
end

__END__
--- a/crypto/perlasm/x86gas.pl	2017-01-26 14:22:03.000000000 +0100
+++ b/crypto/perlasm/x86gas.pl	2017-04-11 00:33:23.000000000 +0200
@@ -160,7 +160,7 @@
     }
     if (grep {/\b${nmdecor}OPENSSL_ia32cap_P\b/i} @out) {
 	my $tmp=".comm\t${nmdecor}OPENSSL_ia32cap_P,16";
-	if ($::macosx)	{ push (@out,"$tmp,2\n"); }
+	if ($::macosx)	{ push (@out,"$tmp\n"); }
 	elsif ($::elf)	{ push (@out,"$tmp,4\n"); }
 	else		{ push (@out,"$tmp\n"); }
     }
--- a/crypto/x86_64cpuid.pl	2017-01-26 14:22:04.000000000 +0100
+++ b/crypto/x86_64cpuid.pl	2017-04-11 16:23:42.000000000 +0200
@@ -24,7 +24,7 @@
 	call	OPENSSL_cpuid_setup
 
 .hidden	OPENSSL_ia32cap_P
-.comm	OPENSSL_ia32cap_P,16,4
+.comm	OPENSSL_ia32cap_P,16
 
 .text
 
--- a/crypto/ec/asm/ecp_nistz256-x86_64.pl	2017-01-26 14:22:03.000000000 +0100
+++ b/crypto/ec/asm/ecp_nistz256-x86_64.pl	2017-04-12 00:20:44.000000000 +0200
@@ -88,7 +88,7 @@
 }
 
 $code.=<<___;
-.text
+.const
 .extern	OPENSSL_ia32cap_P
 
 # The polynomial
@@ -108,6 +108,8 @@
 .long 3,3,3,3,3,3,3,3
 .LONE_mont:
 .quad 0x0000000000000001, 0xffffffff00000000, 0xffffffffffffffff, 0x00000000fffffffe
+
+.text
 ___
 
 {
