import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_treemap/treemap.dart';

class AllocationData {
  final String category;
  final String subCategory;
  final double value;
  final Color color;

  AllocationData(this.category, this.subCategory, this.value, this.color);
}

class AllocationHeatmap extends StatelessWidget {
  final List<AllocationData> data;

  const AllocationHeatmap({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    // Get unique categories and their colors for the legend
    final categories = <String, Color>{};
    for (var item in data) {
      categories[item.category] = item.color;
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Asset Allocation',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                // Legend
                Wrap(
                  spacing: 12,
                  children: categories.entries.map((e) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: e.value.withOpacity(0.8),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(e.key, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  )).toList(),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 220, // Reduced height as requested
              child: SfTreemap(
                dataCount: data.length,
                weightValueMapper: (int index) => data[index].value,
                levels: [
                  TreemapLevel(
                    groupMapper: (int index) => data[index].category,
                    padding: const EdgeInsets.all(1.0),
                    labelBuilder: (BuildContext context, TreemapTile tile) {
                      return const SizedBox.shrink(); // Categories shown in legend/outer color
                    },
                  ),
                  TreemapLevel(
                    groupMapper: (int index) => data[index].subCategory,
                    padding: const EdgeInsets.all(2.0),
                    labelBuilder: (BuildContext context, TreemapTile tile) {
                      if (tile.weight < 1000) return const SizedBox.shrink(); // Hide tiny labels
                      return Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              tile.group,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '\$${tile.weight >= 1000 ? (tile.weight / 1000).toStringAsFixed(1) + "k" : tile.weight.toStringAsFixed(0)}',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.8),
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
                // colorValueMapper is missing in this version, it seems to use the first level by default
                colorMappers: categories.entries.map((e) => TreemapColorMapper.value(
                  value: e.key,
                  color: e.value.withOpacity(0.8),
                )).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
