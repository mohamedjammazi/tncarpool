import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'edit_car.dart'; // Make sure to create and import EditCarPage
import 'add_car.dart';

class MyCarsPage extends StatefulWidget {
  const MyCarsPage({super.key});

  @override
  _MyCarsPageState createState() => _MyCarsPageState();
}

class _MyCarsPageState extends State<MyCarsPage> {
  User? currentUser = FirebaseAuth.instance.currentUser;

  @override
  Widget build(BuildContext context) {
    if (currentUser == null) {
      return const Center(child: Text("لم يتم تسجيل الدخول."));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text("سياراتي"),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const AddCarPage()),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream:
            FirebaseFirestore.instance
                .collection('Users')
                .doc(currentUser!.uid)
                .collection('Cars')
                .orderBy('createdAt', descending: true)
                .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text("خطأ: ${snapshot.error}"));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final cars = snapshot.data!.docs;
          if (cars.isEmpty) {
            return const Center(child: Text("لا توجد سيارات مسجلة."));
          }
          return ListView.builder(
            itemCount: cars.length,
            itemBuilder: (context, index) {
              var car = cars[index];
              return Card(
                margin: const EdgeInsets.all(8.0),
                child: ListTile(
                  title: Text(car['model'] ?? ''),
                  subtitle: Text(
                    "لوحة: ${car['licensePlate']}\nالمقاعد: ${car['availableSeats']}",
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blueAccent),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder:
                                  (context) => EditCarPage(
                                    carId: car.id,
                                    initialData:
                                        car.data() as Map<String, dynamic>,
                                  ),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () async {
                          await car.reference.delete();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("تم حذف السيارة")),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
