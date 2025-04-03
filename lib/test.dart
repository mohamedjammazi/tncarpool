import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class MyDbPage extends StatelessWidget {
  const MyDbPage({super.key});

  // Function to fetch Firestore data structure
  Future<void> fetchFirestoreData(BuildContext context) async {
    FirebaseFirestore firestore = FirebaseFirestore.instance;

    // Manually specify top-level collections
    List<String> collectionNames = ["Users", "Rides", "Bookings", "RideChats"];

    for (String collectionName in collectionNames) {
      CollectionReference collectionRef = firestore.collection(collectionName);
      QuerySnapshot collectionSnapshot = await collectionRef.get();

      print("📂 Collection: $collectionName");

      for (var doc in collectionSnapshot.docs) {
        print("  📄 Document ID: ${doc.id}");
        print("    📑 Data: ${doc.data()}");

        // Manually check known subcollections
        if (collectionName == "Users") {
          var carsRef = doc.reference.collection("Cars");
          var carsSnapshot = await carsRef.get();
          for (var car in carsSnapshot.docs) {
            print("    🚗 Car ID: ${car.id}");
            print("      📑 Data: ${car.data()}");
          }
        }

        if (collectionName == "RideChats") {
          var messagesRef = doc.reference.collection("Messages");
          var messagesSnapshot = await messagesRef.get();
          for (var msg in messagesSnapshot.docs) {
            print("    💬 Message ID: ${msg.id}");
            print("      📑 Data: ${msg.data()}");
          }
        }
      }
    }

    // After fetching the data, you can display a message to indicate completion
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Firestore Data fetched successfully!")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Firestore Database Structure")),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            fetchFirestoreData(
              context,
            ); // Calls function to fetch Firestore structure
          },
          child: const Text("Fetch Firestore Data"),
        ),
      ),
    );
  }
}
