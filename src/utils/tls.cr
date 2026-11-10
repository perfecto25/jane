require "openssl"

## tls.cr — certificate details Crystal's OpenSSL bindings don't expose

@[Link("crypto")]
lib LibJaneCrypto
  fun x509_get0_not_after = X509_get0_notAfter(x : Void*) : Void*
  # Difference between two ASN1 times; `from` NULL means now.
  fun asn1_time_diff = ASN1_TIME_diff(pday : Int32*, psec : Int32*, from : Void*, to : Void*) : Int32
end

module Jane
  module TLSInfo
    extend self

    # Days until the certificate's notAfter date (negative once expired).
    def days_left(cert : OpenSSL::X509::Certificate) : Float64
      not_after = LibJaneCrypto.x509_get0_not_after(cert.to_unsafe.as(Void*))
      raise "certificate has no expiry date" if not_after.null?
      if LibJaneCrypto.asn1_time_diff(out days, out secs, Pointer(Void).null, not_after) != 1
        raise "cannot read the certificate expiry date"
      end
      days + secs / 86400.0
    end

    # The certificate's CN (or whole subject if there's no CN).
    def subject(cert : OpenSSL::X509::Certificate) : String
      entries = cert.subject.to_a
      cn = entries.find { |(k, _)| k == "CN" }
      cn ? "CN=#{cn[1]}" : entries.map { |(k, v)| "#{k}=#{v}" }.join(", ")
    rescue
      "unknown subject"
    end
  end
end
