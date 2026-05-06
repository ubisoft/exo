def print_startup_banner(port: int) -> None:
    """Print a prominent startup banner with API endpoint information."""
    dashboard_url = f"http://localhost:{port}"
    banner = f"""
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║   ███████╗██╗  ██╗ ██████╗                                            ║
║   ██╔════╝╚██╗██╔╝██╔═══██╗                                           ║
║   █████╗   ╚███╔╝ ██║   ██║                                           ║
║   ██╔══╝   ██╔██╗ ██║   ██║                                           ║
║   ███████╗██╔╝ ██╗╚██████╔╝                                           ║
║   ╚══════╝╚═╝  ╚═╝ ╚═════╝                                            ║
║                                                                       ║
║   Distributed AI Inference Cluster                                    ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║  🌐 Dashboard & API Ready                                             ║
║                                                                       ║
║  {dashboard_url}{" " * (69 - len(dashboard_url))}║
║                                                                       ║
║  Click the URL above to open the dashboard in your browser            ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝

"""

    try:
        print(banner)
    except UnicodeEncodeError:
        import sys
        sys.stdout.buffer.write(banner.encode("utf-8", errors="replace"))
        sys.stdout.buffer.flush()
