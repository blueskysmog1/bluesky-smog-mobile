import 'package:flutter/material.dart';
import 'local_db.dart';
import 'customer_detail_page.dart';

class VehiclesDuePage extends StatefulWidget {
  final String deviceId;
  const VehiclesDuePage({super.key, required this.deviceId});

  @override
  State<VehiclesDuePage> createState() => _VehiclesDuePageState();
}

class _VehiclesDuePageState extends State<VehiclesDuePage> {
  final db = LocalDb.instance;
  List<Map<String, dynamic>> _vehicles = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final rows = await db.getVehiclesDueSoon(days: 90);
    if (!mounted) return;
    setState(() { _vehicles = rows; _loading = false; });
  }

  Color _urgencyColor(String? due) {
    if (due == null) return Colors.grey;
    final date = DateTime.tryParse(due);
    if (date == null) return Colors.grey;
    final days = date.difference(DateTime.now()).inDays;
    if (days < 0)  return Colors.red.shade700;
    if (days < 14) return Colors.red.shade400;
    if (days < 30) return Colors.orange.shade600;
    return Colors.green.shade600;
  }

  String _dueLabel(String? due) {
    if (due == null) return '';
    final date = DateTime.tryParse(due);
    if (date == null) return due;
    final days = date.difference(DateTime.now()).inDays;
    if (days < 0)  return 'OVERDUE by ${(-days)} day${(-days) == 1 ? '' : 's'}';
    if (days == 0) return 'Due TODAY';
    if (days == 1) return 'Due tomorrow';
    return 'Due in $days days';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vehicles Due (90 Days)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () { setState(() => _loading = true); _load(); },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _vehicles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 64, color: Colors.green.shade300),
                      const SizedBox(height: 12),
                      const Text('No vehicles due in the next 90 days',
                          style: TextStyle(fontSize: 16, color: Colors.grey)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _vehicles.length,
                    itemBuilder: (ctx, i) {
                      final v      = _vehicles[i];
                      final due    = v['next_test_due'] as String?;
                      final color  = _urgencyColor(due);
                      final label  = _dueLabel(due);
                      final vin    = (v['vin']   ?? '').toString();
                      final plate  = (v['plate'] ?? '').toString();
                      final ymm    = '${v['year'] ?? ''} ${v['make'] ?? ''} ${v['model'] ?? ''}'.trim();
                      final cname  = (v['company_name'] ?? '').toString().isNotEmpty
                          ? (v['company_name'] ?? '').toString()
                          : '${v['first_name'] ?? ''} ${v['last_name'] ?? ''}'.trim();

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: color.withOpacity(0.15),
                            child: Icon(Icons.directions_car, color: color, size: 22),
                          ),
                          title: Text(
                            ymm.isNotEmpty ? ymm : (vin.isNotEmpty ? vin : 'Vehicle'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (plate.isNotEmpty) Text('Plate: $plate'),
                              if (vin.isNotEmpty)
                                Text(vin, style: const TextStyle(fontSize: 11,
                                    color: Colors.grey)),
                              if (cname.isNotEmpty)
                                Text(cname, style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                due != null
                                    ? due.substring(0, 10)  // YYYY-MM-DD
                                    : '',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: color, fontSize: 13),
                              ),
                              Text(label,
                                  style: TextStyle(fontSize: 11, color: color)),
                            ],
                          ),
                          onTap: () {
                            final cid = (v['customer_id'] ?? '').toString();
                            if (cid.isEmpty) return;
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => CustomerDetailPage(
                                customerId: cid,
                                deviceId: widget.deviceId,
                              ),
                            ));
                          },
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
