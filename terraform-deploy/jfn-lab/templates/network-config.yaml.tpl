version: 2
ethernets:
  lab0:
    match:
      macaddress: "${mac}"
    dhcp4: false
    addresses:
      - ${ip}/${prefix}
    routes:
      - to: 0.0.0.0/0
        via: ${gateway}
    nameservers:
      addresses: [${gateway}, 1.1.1.1]
