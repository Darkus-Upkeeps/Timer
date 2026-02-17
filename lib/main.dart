// Function to show the edit timer dialog
void _editTimerDialog(BuildContext context, Timer timer) {
  String newName = timer.name;
  String newProduct = timer.product;

  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text('Edit Timer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              decoration: InputDecoration(labelText: 'Timer Name'),
              onChanged: (value) {
                newName = value;
              },
              controller: TextEditingController(text: timer.name),
            ),
            TextField(
              decoration: InputDecoration(labelText: 'Product'),
              onChanged: (value) {
                newProduct = value;
              },
              controller: TextEditingController(text: timer.product),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            child: Text('Cancel'),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
          TextButton(
            child: Text('Save'),
            onPressed: () {
              // Logic to update timer in database
              updateTimerInDatabase(timer.id, newName, newProduct);
              Navigator.of(context).pop();
            },
          ),
        ],
      );
    },
  );
}

// Adding edit button in the timer card UI
Widget buildTimerCard(Timer timer) {
  return Card(
    child: ListTile(
      title: Text(timer.name),
      subtitle: Text(timer.product),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            icon: Icon(Icons.edit),
            onPressed: () {
              _editTimerDialog(context, timer);
            },
          ),
          IconButton(
            icon: Icon(Icons.delete),
            onPressed: () {
              // Logic to delete timer
            },
          ),
        ],
      ),
    ),
  );
}
