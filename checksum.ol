interface ChecksumInterface {
  RequestResponse:
    sha256( string )( string ),
    base64Encode( string )( string ),
    base64Decode( string )( string ),
    getPrefixEndBase64( string )( string ),
    hashToInt( string )( int )
}

service Checksum {
  inputPort Input {
    location: "local"
    interfaces: ChecksumInterface
  } 
  
  foreign java {
    class: "jfn.Checksum"
  }
}