"""
Geohash utility for GPS-based local feed queries.
Geohash encodes lat/lng into a string; matching prefixes = nearby locations.
"""

# Base32 characters for geohash
BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"


def encode(latitude: float, longitude: float, precision: int = 8) -> str:
    """
    Encode latitude/longitude to geohash string.
    
    precision 4 = ~40km radius
    precision 5 = ~5km radius
    precision 6 = ~1.2km radius
    precision 7 = ~150m radius
    precision 8 = ~40m radius
    """
    lat_interval = (-90.0, 90.0)
    lon_interval = (-180.0, 180.0)
    geohash = []
    bits = [16, 8, 4, 2, 1]
    bit = 0
    ch = 0
    is_even = True

    while len(geohash) < precision:
        if is_even:
            mid = (lon_interval[0] + lon_interval[1]) / 2
            if longitude >= mid:
                ch |= bits[bit]
                lon_interval = (mid, lon_interval[1])
            else:
                lon_interval = (lon_interval[0], mid)
        else:
            mid = (lat_interval[0] + lat_interval[1]) / 2
            if latitude >= mid:
                ch |= bits[bit]
                lat_interval = (mid, lat_interval[1])
            else:
                lat_interval = (lat_interval[0], mid)
        
        is_even = not is_even
        
        if bit < 4:
            bit += 1
        else:
            geohash.append(BASE32[ch])
            bit = 0
            ch = 0
    
    return "".join(geohash)


def get_neighbors(geohash: str) -> list:
    """
    Get all 8 neighboring geohashes plus the center.
    Used for radius queries (search 9 cells).
    """
    # Simplified: just return prefix variants for range queries
    if len(geohash) < 2:
        return [geohash]
    
    prefix = geohash[:-1]
    last_char = geohash[-1]
    last_idx = BASE32.index(last_char)
    
    neighbors = [geohash]
    
    # Add adjacent characters
    if last_idx > 0:
        neighbors.append(prefix + BASE32[last_idx - 1])
    if last_idx < 31:
        neighbors.append(prefix + BASE32[last_idx + 1])
    
    return neighbors


def get_prefix_for_radius(radius_km: float) -> int:
    """
    Get geohash precision for approximate radius.
    """
    if radius_km <= 1:
        return 6  # ~1.2km
    elif radius_km <= 5:
        return 5  # ~5km
    elif radius_km <= 20:
        return 4  # ~20km
    elif radius_km <= 80:
        return 3  # ~80km
    else:
        return 2  # ~600km


def get_nearby_prefixes(lat: float, lon: float, radius_km: float) -> list:
    """
    Get list of geohash prefixes to query for nearby posts.
    
    Example:
        prefixes = get_nearby_prefixes(35.7, 51.4, 10)
        # Query: WHERE geohash LIKE 'abc%' OR geohash LIKE 'abd%' ...
    """
    precision = get_prefix_for_radius(radius_km)
    center = encode(lat, lon, precision)
    return get_neighbors(center)
