import struct
import sys
import os

# Increase recursion limit just in case some polylines are extremely long
sys.setrecursionlimit(20000)

def perp_dist(p, a, b):
    # Calculate perpendicular distance of point p from line segment ab
    if a[0] == b[0] and a[1] == b[1]:
        return ((p[0] - a[0])**2 + (p[1] - a[1])**2)**0.5
    num = abs((b[1] - a[1]) * p[0] - (b[0] - a[0]) * p[1] + b[0] * a[1] - b[1] * a[0])
    den = ((b[1] - a[1])**2 + (b[0] - a[0])**2)**0.5
    return num / den

def rdp(points, epsilon):
    if len(points) < 3:
        return points
    
    dmax = 0
    idx = 0
    end = len(points) - 1
    for i in range(1, end):
        d = perp_dist(points[i], points[0], points[end])
        if d > dmax:
            idx = i
            dmax = d
            
    if dmax > epsilon:
        return rdp(points[:idx+1], epsilon)[:-1] + rdp(points[idx:], epsilon)
    return [points[0], points[end]]

def parse_shp(shp_path, out_path, epsilon=0.02):
    print(f"Reading shapefile from {shp_path}...")
    if not os.path.exists(shp_path):
        print(f"Error: {shp_path} does not exist.")
        sys.exit(1)
        
    with open(shp_path, "rb") as f:
        header = f.read(100)
        if len(header) < 100:
            print("Error: File too short.")
            sys.exit(1)
            
        fields = struct.unpack(">7i", header[:28])
        file_code = fields[0]
        if file_code != 9994:
            print(f"Error: Invalid file code {file_code}")
            sys.exit(1)
            
        version = struct.unpack("<i", header[28:32])[0]
        shape_type = struct.unpack("<i", header[32:36])[0]
        print(f"Shapefile version: {version}, shape type: {shape_type}")
        
        polylines = []
        raw_points_count = 0
        simplified_points_count = 0
        
        while True:
            rec_header = f.read(8)
            if len(rec_header) < 8:
                break
                
            rec_num, content_len_words = struct.unpack(">2i", rec_header)
            content_len_bytes = content_len_words * 2
            
            rec_bytes = f.read(content_len_bytes)
            if len(rec_bytes) < content_len_bytes:
                break
                
            if content_len_bytes < 4:
                continue
                
            rec_shape_type = struct.unpack("<i", rec_bytes[:4])[0]
            if rec_shape_type == 0:
                continue
            if rec_shape_type not in (3, 5):
                continue
                
            if len(rec_bytes) < 44:
                continue
                
            num_parts, num_points = struct.unpack("<2i", rec_bytes[36:44])
            
            parts_offset = 44
            points_offset = parts_offset + 4 * num_parts
            
            if len(rec_bytes) < points_offset + 16 * num_points:
                continue
                
            parts = list(struct.unpack(f"<{num_parts}i", rec_bytes[parts_offset:points_offset]))
            
            coords = []
            for i in range(num_points):
                offset = points_offset + i * 16
                x, y = struct.unpack("<2d", rec_bytes[offset:offset+16])
                coords.append((float(x), float(y)))
                
            parts_indices = parts + [num_points]
            for p in range(num_parts):
                start = parts_indices[p]
                end = parts_indices[p+1]
                part_coords = coords[start:end]
                if len(part_coords) >= 2:
                    raw_points_count += len(part_coords)
                    # Apply RDP simplification
                    simplified = rdp(part_coords, epsilon)
                    simplified_points_count += len(simplified)
                    polylines.append(simplified)
                    
        print(f"Total raw points: {raw_points_count}")
        print(f"Total simplified points (epsilon={epsilon}): {simplified_points_count}")
        print(f"Number of simplified polylines: {len(polylines)}")
        
        # Write to binary file
        with open(out_path, "wb") as out:
            out.write(struct.pack("<I", len(polylines)))
            for pl in polylines:
                out.write(struct.pack("<I", len(pl)))
                for lon, lat in pl:
                    out.write(struct.pack("<2f", lon, lat))
                    
        print(f"Wrote to {out_path} ({os.path.getsize(out_path)} bytes).")

if __name__ == "__main__":
    shp = "resources/ne_10m_admin_0_boundary_lines_land/ne_10m_admin_0_boundary_lines_land.shp"
    out = "resources/borders.bin"
    parse_shp(shp, out, epsilon=0.02)
