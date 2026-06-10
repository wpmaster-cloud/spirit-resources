import os
import sys
from urllib.parse import urlparse

def setup_vpn():
    """
    Sets up VPN proxy environment variables based on VPN_PROXY and NIM_API_URL.
    Mimics the logic found in internal/hooks/vpn_setup.go.
    """
    vpn_proxy = os.getenv("VPN_PROXY", "").strip()
    if not vpn_proxy:
        print("# VPN_PROXY not set. Skipping VPN setup.")
        return

    nim_api_url = os.getenv("NIM_API_URL", "https://integrate.api.nvidia.com").strip()
    
    # Extract host for bypass list
    # logic mimics internal/hooks/vpn_setup.go's extractHost
    parsed = urlparse(nim_api_url)
    llm_host = parsed.hostname or "integrate.api.nvidia.com"
    
    no_proxy = f"localhost,127.0.0.1,0.0.0.0,.svc.cluster.local,.cluster.local,10.0.0.0/8,{llm_host}"
    
    # Print export commands so the script can be evaled: 
    # eval $(python setup_vpn.py)
    print(f'export HTTP_PROXY="{vpn_proxy}"')
    print(f'export HTTPS_PROXY="{vpn_proxy}"')
    print(f'export http_proxy="{vpn_proxy}"')
    print(f'export https_proxy="{vpn_proxy}"')
    print(f'export NO_PROXY="{no_proxy}"')
    print(f'export no_proxy="{no_proxy}"')
    
    print(f"# VPN Proxy setup complete: {vpn_proxy}", file=sys.stderr)
    print(f"# Bypassing: {no_proxy}", file=sys.stderr)

if __name__ == "__main__":
    setup_vpn()
