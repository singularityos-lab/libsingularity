namespace Singularity {

    /**
     * Minimal DDC/CI client for reading and writing monitor VCP features over
     * a Linux i2c-dev bus, enough to drive the brightness of external displays.
     */
    public class Ddc : Object {
        public const uint8 VCP_BRIGHTNESS = 0x10;
        private const uint8 DDC_ADDRESS = 0x37;
        private const uint8 HOST_ADDRESS = 0x51;
        private const uint8 WRITE_CHECKSUM_SEED = 0x6E;
        private const uint8 READ_CHECKSUM_SEED = 0x50;
        private const ulong I2C_SLAVE = 0x0703;

        public string device_path { get; construct; }

        public Ddc(string device_path) {
            Object(device_path: device_path);
        }

        internal static uint8[] encode_get_vcp(uint8 code) {
            uint8[] packet = { HOST_ADDRESS, 0x82, 0x01, code, 0 };
            packet[4] = checksum(packet[0:4], WRITE_CHECKSUM_SEED);
            return packet;
        }

        internal static uint8[] encode_set_vcp(uint8 code, uint16 value) {
            uint8[] packet = { HOST_ADDRESS, 0x84, 0x03, code, (uint8) (value >> 8), (uint8) (value & 0xff), 0 };
            packet[6] = checksum(packet[0:6], WRITE_CHECKSUM_SEED);
            return packet;
        }

        internal static bool decode_vcp_reply(uint8[] reply, uint8 code, out uint16 current, out uint16 maximum) {
            current = 0;
            maximum = 0;
            if (reply.length < 11 || reply[1] != 0x88 || reply[2] != 0x02) return false;
            if (reply[3] != 0x00 || reply[4] != code) return false;
            if (checksum(reply[0:10], READ_CHECKSUM_SEED) != reply[10]) return false;
            maximum = (uint16) ((reply[6] << 8) | reply[7]);
            current = (uint16) ((reply[8] << 8) | reply[9]);
            return maximum > 0;
        }

        private static uint8 checksum(uint8[] bytes, uint8 seed) {
            uint8 sum = seed;
            foreach (uint8 b in bytes) sum ^= b;
            return sum;
        }

        public bool get_vcp(uint8 code, out uint16 current, out uint16 maximum) {
            current = 0;
            maximum = 0;
            int fd = open_bus();
            if (fd < 0) return false;
            uint8[] request = encode_get_vcp(code);
            bool ok = Posix.write(fd, request, request.length) == request.length;
            if (ok) {
                Thread.usleep(40000);
                uint8[] reply = new uint8[11];
                ok = Posix.read(fd, reply, reply.length) == reply.length
                    && decode_vcp_reply(reply, code, out current, out maximum);
            }
            Posix.close(fd);
            return ok;
        }

        public bool set_vcp(uint8 code, uint16 value) {
            int fd = open_bus();
            if (fd < 0) return false;
            uint8[] request = encode_set_vcp(code, value);
            bool ok = Posix.write(fd, request, request.length) == request.length;
            Posix.close(fd);
            Thread.usleep(50000);
            return ok;
        }

        private int open_bus() {
            int fd = Posix.open(device_path, Posix.O_RDWR);
            if (fd < 0) return -1;
            if (Posix.ioctl(fd, (int) I2C_SLAVE, DDC_ADDRESS) < 0) {
                Posix.close(fd);
                return -1;
            }
            return fd;
        }
    }
}
