package jfn;

import jolie.runtime.JavaService;
import jolie.runtime.Value;
import jolie.runtime.FaultException;
import java.util.Base64;
import java.util.Arrays;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.nio.charset.StandardCharsets;

public class Checksum extends JavaService {
  private static String algo = "SHA-256";

  // taken from https://stackoverflow.com/a/9855338
  private static final byte[] HEX_ARRAY = "0123456789ABCDEF".getBytes(StandardCharsets.US_ASCII);
  
  public static String hex(byte[] bytes) {
      byte[] hexChars = new byte[bytes.length * 2];
      for (int j = 0; j < bytes.length; j++) {
          int v = bytes[j] & 0xFF;
          hexChars[j * 2] = HEX_ARRAY[v >>> 4];
          hexChars[j * 2 + 1] = HEX_ARRAY[v & 0x0F];
      }
      return new String(hexChars, StandardCharsets.UTF_8);
  }

  public String sha256(String s) throws FaultException {
    try {
        MessageDigest md = MessageDigest.getInstance(algo);
        md.update(s.getBytes(StandardCharsets.UTF_8));
        return hex(md.digest());
    } catch(NoSuchAlgorithmException e) {
        Value msg = Value.create();
        msg.getFirstChild("algo").setValue(algo);
        msg.getFirstChild("message").setValue("The required hashing algorithm is not available");
        throw new FaultException("NoSuchAlgorithm", msg);
    }
  }

    public String base64Encode(String s) {
        return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }

    public String base64Decode(String s) {
        return new String(Base64.getDecoder().decode(s), StandardCharsets.UTF_8);
    }

    // Calculates the range_end key for an etcd prefix query.
    public String getPrefixEndBase64(String prefix) {
        byte[] prefixBytes = prefix.getBytes(StandardCharsets.UTF_8);
        byte[] endKey = Arrays.copyOf(prefixBytes, prefixBytes.length);
        
        int i = endKey.length - 1;
        for (; i >= 0; i--) {
            if (endKey[i] != (byte) 0xff) {
                endKey[i] = (byte) (endKey[i] + 1);
                break;
            }
        }
        // Arrays.copyOf correctly truncates the array if bytes wrapped around to 0x00
        return Base64.getEncoder().encodeToString(Arrays.copyOf(endKey, i + 1));
    }
}
