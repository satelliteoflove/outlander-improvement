#!/usr/bin/env python3
"""Serves one directory over HTTP for tools/video.py serve: the page with the comparison
video, for other machines on the LAN.  Answers Range requests (python3 -m http.server does
not, and without them a phone will not play or seek a video).  Nothing outside the
directory is served, and no directory listings.

  tools/vserve.py DIR [PORT]
"""
import http.server, os, re, socket, sys


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def list_directory(self, path):
        self.send_error(404); return None

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path): path = os.path.join(path, 'index.html')
        root = os.path.realpath(self.directory)
        if not os.path.realpath(path).startswith(root + os.sep) or not os.path.isfile(path):
            self.send_error(404); return None
        f = open(path, 'rb')
        size = os.fstat(f.fileno()).st_size
        lo, hi, code = 0, size - 1, 200
        m = re.fullmatch(r'bytes=(\d*)-(\d*)', self.headers.get('Range', '').strip())
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                lo = int(m.group(1)); hi = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
            else:
                lo = max(size - int(m.group(2)), 0)
            if lo > hi or lo >= size:
                f.close()
                self.send_response(416); self.send_header('Content-Range', 'bytes */%d' % size)
                self.send_header('Content-Length', '0'); self.end_headers(); return None
            code = 206
        self.send_response(code)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Accept-Ranges', 'bytes')
        if code == 206: self.send_header('Content-Range', 'bytes %d-%d/%d' % (lo, hi, size))
        self.send_header('Content-Length', str(hi - lo + 1))
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        f.seek(lo); self.left = hi - lo + 1
        return f

    def copyfile(self, src, dst):
        left = self.left
        while left > 0:
            b = src.read(min(left, 1 << 16))
            if not b: break
            try: dst.write(b)
            except (BrokenPipeError, ConnectionResetError): break       # (the player went elsewhere)
            left -= len(b)


def lan_address():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('192.0.2.1', 9)); return s.getsockname()[0]            # (no packet is sent)
    except OSError:
        return socket.gethostname()
    finally:
        s.close()


def serve(directory, port=8000):
    h = lambda *a, **k: Handler(*a, directory=directory, **k)
    srv = http.server.ThreadingHTTPServer(('0.0.0.0', port), h)
    print('http://%s:%d/   (this machine: http://localhost:%d/)   Ctrl-C to stop' % (lan_address(), port, port), flush=True)
    try: srv.serve_forever()
    except KeyboardInterrupt: pass


if __name__ == '__main__':
    serve(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 8000)
