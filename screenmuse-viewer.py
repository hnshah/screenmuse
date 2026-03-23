#!/usr/bin/env python3
"""
Simple web server to view ScreenMuse screenshots and videos locally.
Automatically serves files from test output directory.
"""

import http.server
import socketserver
import os
from pathlib import Path

PORT = 8080
DIRECTORY = "/tmp/screenmuse-test-output"

class CustomHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)
    
    def list_directory(self, path):
        """Enhanced directory listing with thumbnails for images"""
        try:
            file_list = sorted(os.listdir(path))
        except OSError:
            return None
        
        # Build HTML
        html = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>ScreenMuse Test Outputs</title>
            <style>
                body {{
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    max-width: 1200px;
                    margin: 0 auto;
                    padding: 20px;
                    background: #f5f5f5;
                }}
                h1 {{
                    color: #333;
                }}
                .gallery {{
                    display: grid;
                    grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
                    gap: 20px;
                    margin-top: 20px;
                }}
                .item {{
                    background: white;
                    border-radius: 8px;
                    padding: 15px;
                    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                }}
                .item img {{
                    width: 100%;
                    border-radius: 4px;
                    cursor: pointer;
                }}
                .item video {{
                    width: 100%;
                    border-radius: 4px;
                }}
                .item h3 {{
                    margin: 10px 0 5px 0;
                    font-size: 14px;
                    color: #666;
                }}
                .item .size {{
                    font-size: 12px;
                    color: #999;
                }}
                a {{
                    color: #007AFF;
                    text-decoration: none;
                }}
                a:hover {{
                    text-decoration: underline;
                }}
            </style>
        </head>
        <body>
            <h1>🎬 ScreenMuse Test Outputs</h1>
            <p>Directory: <code>{DIRECTORY}</code></p>
            <div class="gallery">
        """
        
        for name in file_list:
            if name.startswith('.'):
                continue
            
            fullpath = os.path.join(path, name)
            size = os.path.getsize(fullpath)
            size_str = f"{size / 1024:.1f} KB" if size < 1024 * 1024 else f"{size / (1024*1024):.1f} MB"
            
            if name.endswith('.png') or name.endswith('.jpg'):
                html += f"""
                <div class="item">
                    <a href="{name}" target="_blank">
                        <img src="{name}" alt="{name}">
                    </a>
                    <h3>{name}</h3>
                    <div class="size">{size_str}</div>
                </div>
                """
            elif name.endswith('.mp4') or name.endswith('.mov'):
                html += f"""
                <div class="item">
                    <video controls>
                        <source src="{name}" type="video/mp4">
                    </video>
                    <h3><a href="{name}" download>{name}</a></h3>
                    <div class="size">{size_str}</div>
                </div>
                """
            else:
                html += f"""
                <div class="item">
                    <h3><a href="{name}" download>📄 {name}</a></h3>
                    <div class="size">{size_str}</div>
                </div>
                """
        
        html += """
            </div>
        </body>
        </html>
        """
        
        encoded = html.encode('utf-8', 'surrogateescape')
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
        return None

if __name__ == "__main__":
    # Create directory if it doesn't exist
    Path(DIRECTORY).mkdir(parents=True, exist_ok=True)
    
    # Create some sample files if directory is empty
    if not list(Path(DIRECTORY).glob("*")):
        print(f"📁 Creating sample files in {DIRECTORY}")
        (Path(DIRECTORY) / "README.txt").write_text(
            "ScreenMuse test outputs will appear here after running tests."
        )
    
    with socketserver.TCPServer(("", PORT), CustomHTTPRequestHandler) as httpd:
        print("=" * 60)
        print("🎬 ScreenMuse Media Viewer")
        print("=" * 60)
        print(f"\n📡 Server running at:")
        print(f"   http://localhost:{PORT}")
        print(f"\n📂 Serving files from:")
        print(f"   {DIRECTORY}")
        print(f"\n💡 Open the URL above in your browser to view screenshots/videos")
        print(f"\n⏹️  Press Ctrl+C to stop")
        print("=" * 60)
        print()
        
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n\n👋 Server stopped")
