stub = bytearray(64)
stub[0] = 0x4D
stub[1] = 0x5A
with open('min_stub.bin', 'wb') as f:
    f.write(stub)